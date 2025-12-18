# @author Gabriel Edera
module BugBunny
  # Clase principal para la interacción de bajo nivel con RabbitMQ usando la gema Bunny.
  #
  # Esta clase actúa como un "Driver" que maneja:
  # 1. La gestión de conexiones (Singleton) y recuperación ante fallos.
  # 2. La publicación de mensajes (Fire-and-forget).
  # 3. El patrón RPC (Request-Reply) síncrono sobre colas asíncronas.
  # 4. El consumo de mensajes y enrutamiento hacia controladores.
  class Rabbit
    include ActiveModel::Model
    include ActiveModel::Attributes

    # @api private
    DEFAULT_EXCHANGE_OPTIONS = { durable: false, auto_delete: false }.freeze

    # DEFAULT_MAX_PRIORITY = 10

    # @api private
    DEFAULT_QUEUE_OPTIONS = {
      exclusive: false,
      durable: false,
      auto_delete: true,
      # arguments: { 'x-max-priority' => DEFAULT_MAX_PRIORITY }
    }.freeze

    # La conexión activa con el broker RabbitMQ.
    # @return [Bunny::Session]
    attr_accessor :connection

    # @param value [Bunny::Session]
    attr_accessor :queue

    # La cola actual configurada en esta instancia.
    # @return [Bunny::Queue]
    attr_accessor :exchange

    class << self
      # Obtiene la conexión actual a RabbitMQ (Singleton).
      # Reutiliza la conexión si ya existe y está abierta para optimizar recursos.
      #
      # @return [Bunny::Session] La sesión activa de Bunny.
      # @raise [BugBunny::CommunicationError] Si no se puede establecer conexión.
      def connection
        return @connection if @connection&.open?

        @connection = create_connection
      end

      # Cierra la conexión actual y limpia la variable de clase.
      #
      # IMPORTANTE: Este método debe llamarse al hacer un fork del proceso (ej: en Puma o Spring)
      # para evitar compartir descriptores de archivo entre procesos padres e hijos.
      #
      # @return [void]
      def disconnect
        return unless @connection

        @connection.close if @connection.open?
        @connection = nil
        BugBunny.configuration.logger.info("[BugBunny] RabbitMQ connection closed successfully.")
      end

      # Inicia el bucle principal de un Consumidor (Worker).
      # Este método bloquea el hilo actual y se queda escuchando mensajes indefinidamente.
      #
      # @param connection [Bunny::Session] La conexión a utilizar.
      # @param exchange [String] Nombre del exchange a escuchar.
      # @param exchange_type [String] Tipo de exchange ('direct', 'topic', 'fanout').
      # @param queue_name [String] Nombre de la cola donde llegarán los mensajes.
      # @param routing_key [String] Routing key para hacer el binding Exchange <-> Cola.
      # @param queue_opts [Hash] Opciones extra para la cola.
      # @raise [RuntimeError] Si falla el health check.
      def run_consumer(connection:, exchange:, exchange_type:, queue_name:, routing_key:, queue_opts: {})
        app = new(connection: connection)
        app.build_exchange(name: exchange, type: exchange_type)
        app.build_queue(name: queue_name, opts: queue_opts)
        app.queue.bind(app.exchange, routing_key: routing_key)
        # Inicia el consumo (bloqueante en la lógica interna de Bunny si se configura así,
        # pero aquí delegamos el control al health check)
        app.consume!
        # Mantiene el proceso vivo vigilando que la cola exista
        health_check_thread = start_health_check(app, queue_name: queue_name, exchange_name: exchange, exchange_type: exchange_type)
        health_check_thread.wait_for_termination
        raise 'Health check error: Forcing reconnect.'
      rescue StandardError => e
        # Esto lo pongo por que si levanto el rabbit y el consumer a la vez
        # El rabbit esta una banda de tiempo hasta aceptar conexiones, por lo que
        # el consumer explota 2 millones de veces, por lo tanto con esto hago
        # la espera ocupada y me evito de ponerlo en el entrypoint-docker
        BugBunny.configuration.logger.error("[RABBIT] Consumer error: #{e.message} (#{e.class})")
        BugBunny.configuration.logger.debug("[RABBIT] Consumer error: #{e.backtrace}")
        connection&.close
        sleep BugBunny.configuration.network_recovery_interval
        retry
      end

      # Inicia un hilo de fondo para verificar periódicamente que la infraestructura existe.
      # @api private
      def start_health_check(app, queue_name:, exchange_name:, exchange_type:)
        task = Concurrent::TimerTask.new(execution_interval: BugBunny.configuration.health_check_interval) do
          # Verificación pasiva: si no existe, Rabbit lanza excepción
          app.channel.exchange_declare(exchange_name, exchange_type, passive: true)
          app.channel.queue_declare(queue_name, passive: true)
        rescue Bunny::NotFound
          Rails.logger.error("Health check failed: Queue '#{queue_name}' no longer exists!")
          app.connection.close
          task.shutdown # Detenemos la tarea para que no se ejecute de nuevo
        rescue StandardError => e
          Rails.logger.error("Health check error: #{e.message}. Forcing reconnect.")
          app.connection.close
          task.shutdown
        end

        task.execute
        task
      end

      # Factory method para crear una nueva conexión Bunny con los parámetros de configuración.
      # @api private
      def create_connection(host: nil, username: nil, password: nil, vhost: nil)
        bunny = Bunny.new(
          host: host || BugBunny.configuration.host,
          username: username || BugBunny.configuration.username,
          password: password || BugBunny.configuration.password,
          vhost: vhost || BugBunny.configuration.vhost,
          logger: BugBunny.configuration.logger || Rails.logger,
          automatically_recover: BugBunny.configuration.automatically_recover || false,
          network_recovery_interval: BugBunny.configuration.network_recovery_interval || 5,
          connection_timeout: BugBunny.configuration.connection_timeout || 10,
          read_timeout: BugBunny.configuration.read_timeout || 90,
          write_timeout: BugBunny.configuration.write_timeout || 90,
          heartbeat: BugBunny.configuration.heartbeat || 30,
          continuation_timeout: BugBunny.configuration.continuation_timeout || 15_000
        )

        bunny.tap(&:start)
      rescue Timeout::Error, Bunny::ConnectionError => e
        # Timeout::Error (para el timeout de conexión TCP) se captura separadamente.
        # Bunny::ConnectionError cubre TCPConnectionFailed, AuthenticationFailure, AccessRefused, etc.
        raise BugBunny::CommunicationError, e.message
      end
    end

    # Inicializa una instancia de Rabbit.
    # Si no se pasa conexión, utiliza la conexión global (Singleton).
    #
    # @param attrs [Hash] Atributos iniciales para ActiveModel.
    # @api public
    def initialize(attrs = {})
      super(attrs)
      self.connection ||= self.class.connection
    end

    # Obtiene o crea un canal de comunicación de forma segura (Thread-safe).
    #
    # @return [Bunny::Channel] El canal activo.
    def channel
      @channel_mutex ||= Mutex.new
      return @channel if @channel&.open?

      @channel_mutex.synchronize do
        return @channel if @channel&.open?

        @channel = connection.create_channel
        @channel.confirm_select
        @channel.prefetch(BugBunny.configuration.channel_prefetch) # Limita mensajes concurrentes por consumidor
        @channel
      end
    end

    # Declara o recupera un Exchange en RabbitMQ.
    #
    # @param name [String] Nombre del exchange (ej: 'bugbunny.users').
    # @param type [String] Tipo de enrutamiento ('direct', 'topic', 'fanout').
    # @param opts [Hash] Opciones adicionales (durable, auto_delete).
    # @return [Bunny::Exchange] La instancia del exchange.
    def build_exchange(name: nil, type: 'direct', opts: {})
      return @exchange if defined?(@exchange)

      exchange_options = DEFAULT_EXCHANGE_OPTIONS.merge(opts.compact)

      if name.blank?
        @exchange = channel.default_exchange
        return @exchange
      end

      BugBunny.configuration.logger.info("ExchangeName: #{name}, ExchangeType: #{type}, opts: #{opts}")

      @exchange = case type.to_sym
                  when :topic
                    channel.topic(name, exchange_options)
                  when :direct
                    channel.direct(name, exchange_options)
                  when :fanout
                    channel.fanout(name, exchange_options)
                  when :headers
                    channel.headers(name, exchange_options)
                  end
    end

    # Genera las opciones por defecto para la publicación de mensajes.
    # Incluye timestamp y un UUID único para traza (Correlation ID).
    # @api private
    def default_publish_options
      @default_publish_opts ||= {
        persistent: false,
        app_id: Rails.application.class.module_parent_name
      }.freeze

      # Solo generamos valores dinámicos por llamada
      @default_publish_opts.merge(
        timestamp: Time.current.to_i,
        correlation_id: SecureRandom.uuid
      )
    end

    # Declara una cola en RabbitMQ.
    #
    # @param name [String] Nombre de la cola.
    # @param opts [Hash] Opciones (exclusive, durable, etc).
    # @return [Bunny::Queue]
    def build_queue(name: '', opts: {})
      name = name.to_s
      queue_options = DEFAULT_QUEUE_OPTIONS.merge(opts.compact)
      BugBunny.configuration.logger.info("QueueName: #{name}, opts: #{queue_options}")
      @queue = channel.queue(name, queue_options)
    end

    # Publica un mensaje asíncrono (Fire and Forget).
    # No espera respuesta del consumidor.
    #
    # @param msg [String, Hash] El mensaje a enviar. Se convierte a JSON si es Hash.
    # @param opts [Hash] Opciones de publicación (routing_key, headers).
    # @raise [BugBunny::CommunicationError] Si falla la conexión con RabbitMQ.
    def publish!(msg, opts)
      options = default_publish_options.merge(opts.compact)

      msg = msg.instance_of?(Hash) ? msg.to_json : msg.to_s

      BugBunny.configuration.logger.info("Message: #{msg}")
      BugBunny.configuration.logger.info("Options: #{options}")

      exchange.publish(msg, options)
      # channel.wait_for_confirms # Esto solo confirma que el mensaje llego el exchange
    rescue Bunny::Exception => e
      BugBunny.configuration.logger.error(e)
      raise BugBunny::CommunicationError, e.message
    end

    # Publica un mensaje y espera una respuesta síncrona (Patrón RPC).
    # Utiliza una cola temporal exclusiva (reply_to) y espera con un latch.
    #
    # @param msg [String, Hash] El mensaje a enviar.
    # @param opts [Hash] Opciones de publicación.
    # @return [Hash, Array, nil] La respuesta procesada del microservicio remoto.
    #
    # @raise [BugBunny::RequestTimeout] Si no se recibe respuesta en `rpc_timeout` segundos.
    # @raise [BugBunny::BadRequest] (400) Datos inválidos.
    # @raise [BugBunny::NotFound] (404) Recurso no encontrado.
    # @raise [BugBunny::UnprocessableEntity] (422) Errores de validación.
    # @raise [BugBunny::InternalServerError] (500) Error en el servicio remoto.
    def publish_and_consume!(msg, opts)
      options = default_publish_options.merge(opts.compact)

      # Latch para bloquear el hilo hasta recibir respuesta
      response_latch = Concurrent::CountDownLatch.new(1)
      response = nil

      # Cola efímera para recibir la respuesta de este request específico
      reply_queue = channel.queue('', exclusive: true, durable: false, auto_delete: true)
      options[:reply_to] = reply_queue.name

      subscription = reply_queue.subscribe(manual_ack: true, block: false) do |delivery_info, properties, body|
        BugBunny.configuration.logger.debug("CONSUMER DeliveryInfo: #{delivery_info}")
        BugBunny.configuration.logger.debug("CONSUMER Properties: #{properties}")
        BugBunny.configuration.logger.debug("CONSUMER Body: #{body}")

        # Validamos que la respuesta corresponda a nuestra petición
        if properties.correlation_id == options[:correlation_id]
          response = ActiveSupport::JSON.decode(body).deep_symbolize_keys.with_indifferent_access
          channel.ack(delivery_info.delivery_tag)
          response_latch.count_down # Libera el bloqueo del hilo principal
        else
          BugBunny.configuration.logger.debug('Correlation_id not match')
          # Si el correlation_id no coincide, rechazamos el mensaje para que RabbitMQ lo maneje
          channel.reject(delivery_info.delivery_tag, false)
        end
      end

      BugBunny.configuration.logger.debug("PUBLISHER Message: #{msg}")
      BugBunny.configuration.logger.debug("PUBLISHER Options: #{options}")
      publish!(msg, options)

      # Esperamos la respuesta con timeout
      if response_latch.wait(BugBunny.configuration.rpc_timeout)
        subscription.cancel
        build_response(status: response[:status], body: response[:body])
      else
        raise "Timeout: No response received within #{BugBunny.configuration.rpc_timeout} seconds."
      end
    rescue BugBunny::Error => e
      subscription&.cancel
      raise e
    rescue RuntimeError => e
      subscription&.cancel
      BugBunny.configuration.logger.error("[Rabbit] Error in publish_and_consume: #{e.class} - <#{e.message}>")
      raise(BugBunny::RequestTimeout, e.message) if e.message.include?('Timeout')

      raise BugBunny::InternalServerError, e.message
    rescue StandardError => e
      subscription&.cancel
      BugBunny.configuration.logger.error("[Rabbit] Error in publish_and_consume: #{e.class} - <#{e.message}>")
      raise BugBunny::Error, e.message
    end

    # Helper para parsear la ruta del mensaje.
    # Formato esperado: "controller/action" o "controller/id/action".
    # @api private
    def parse_route(route)
      # De momento no resuelve anidado
      segments = route.split('/')
      controller_name = segments[0]
      action_name = 'index'
      id = nil

      case segments.length
      when 2
        # Patrón: controller/action (Ej: 'secrets/index', 'swarm/info')
        # Patrón: secrets/index
        action_name = segments[1]
      when 3
        # Patrón: controller/id/action (Ej: 'secrets/123/update', 'services/999/destroy')
        # Patrón: secrets/123/update
        id = segments[1]
        action_name = segments[2]
      end

      { controller: controller_name, action: action_name, id: id }
    end

    # Lógica principal de consumo de mensajes para Workers.
    # 1. Lee el mensaje.
    # 2. Determina el controlador y acción basados en `type`.
    # 3. Ejecuta el controlador.
    # 4. Envía la respuesta (si existe `reply_to`).
    # 5. Hace Acknowledge (ACK).
    # @api private
    def consume!
      queue.subscribe(manual_ack: true, block: true) do |delivery_info, properties, body|
        BugBunny.configuration.logger.debug("DeliveryInfo: #{delivery_info}")
        BugBunny.configuration.logger.debug("Properties: #{properties}")
        BugBunny.configuration.logger.debug("Body: #{body}")

        raise BugBunny::Error, 'Undefined properties.type' if properties.type.blank?

        route = parse_route(properties.type)

        headers = {
          type: properties.type,
          controller: route[:controller],
          action: route[:action],
          id: route[:id],
          content_type: properties.content_type,
          content_encoding: properties.content_encoding,
          correlation_id: properties.correlation_id
        }

        # Magia de Rails: Instancia el controlador dinámicamente
        controller = "rabbit/controllers/#{route[:controller]}".camelize.constantize
        response_payload = controller.call(headers: headers, body: body)

        BugBunny.configuration.logger.debug("Response: #{response_payload}")

        # Si el mensaje espera respuesta (RPC), la enviamos
        if properties.reply_to.present?
          BugBunny.configuration.logger.info("Sending response to #{properties.reply_to}")

          # Publicar la respuesta directamente a la cola de respuesta
          # No se necesita un exchange, se publica a la cola por su nombre
          channel.default_exchange.publish(
            response_payload.to_json,
            routing_key: properties.reply_to,
            correlation_id: properties.correlation_id
          )
        end

        channel.ack(delivery_info.delivery_tag)
      rescue NoMethodError => e # action controller no exist
        BugBunny.configuration.logger.error(e)
        channel.reject(delivery_info.delivery_tag, false)
      rescue NameError => e # Controller no exist
        BugBunny.configuration.logger.error(e)
        channel.reject(delivery_info.delivery_tag, false)
      rescue StandardError => e
        BugBunny.configuration.logger.error("Error processing message: #{e.message} (#{e.class})")
        # Reject the message and do NOT re-queue it immediately.
        channel.reject(delivery_info.delivery_tag, false)
      end
    end

    private

    # Traduce los códigos de estado HTTP recibidos del microservicio a excepciones de Ruby.
    # @param status [Integer] Código de estado (200, 404, 500, etc).
    # @param body [String, Hash] Cuerpo de la respuesta.
    # @raise [BugBunny::Error] La excepción correspondiente al error.
    def build_response(status:, body:)
      case status
      when 'success' then body # Old compatibility
      when 'error' then raise BugBunny::InternalServerError, body # Old compatibility
      when 200, 201 then body
      when 204 then nil
      when 400 then raise BugBunny::BadRequest, "Bad Request: #{body}"
      when 404 then raise BugBunny::NotFound
      when 406 then raise BugBunny::NotAcceptable
      when 422 then raise BugBunny::UnprocessableEntity, body
      when 500 then raise BugBunny::InternalServerError, "Server Error: #{body}"
      else
        raise BugBunny::Error, "Unknown status code #{status}: #{body}"
      end
    end
  end
end
