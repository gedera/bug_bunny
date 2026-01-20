require 'active_support/core_ext/string/inflections'
require 'concurrent'
require 'json'

module BugBunny
  # Clase encargada de consumir mensajes de una cola RabbitMQ.
  #
  # Actúa como el "Servidor" o "Worker" en la arquitectura RPC. Sus responsabilidades son:
  # 1. Declarar la cola y realizar el binding con el Exchange.
  # 2. Escuchar mensajes entrantes de forma bloqueante o no bloqueante.
  # 3. Enrutar el mensaje al {BugBunny::Controller} adecuado basándose en los metadatos.
  # 4. Manejar excepciones y enviar respuestas de error si es necesario.
  # 5. Supervisar la salud de la conexión mediante un hilo secundario.
  class Consumer
    # @return [BugBunny::Session] La sesión de Bunny wrappeada que se utiliza para el canal.
    attr_reader :session

    # Método de conveniencia (Factory) para instanciar y suscribir en un solo paso.
    #
    # @param connection [Bunny::Session] Una conexión activa a RabbitMQ.
    # @param args [Hash] Argumentos que se pasarán directamente al método de instancia {#subscribe}.
    # @return [void]
    def self.subscribe(connection:, **args)
      new(connection).subscribe(**args)
    end

    # Inicializa un nuevo consumidor.
    #
    # @param connection [Bunny::Session] Conexión activa a RabbitMQ.
    def initialize(connection)
      @session = BugBunny::Session.new(connection)
    end

    # Configura la infraestructura (Cola, Exchange, Binding) y comienza a escuchar mensajes.
    #
    # Este método es resiliente: si ocurre un error de conexión, intentará reconectar
    # automáticamente respetando el intervalo configurado.
    #
    # @param queue_name [String] Nombre de la cola a consumir.
    # @param exchange_name [String] Nombre del exchange al cual atar la cola.
    # @param routing_key [String] Patrón de enrutamiento (Binding Key) para filtrar mensajes (ej: 'users.#').
    # @param exchange_type [String] Tipo de exchange ('direct', 'topic', 'fanout'). Por defecto: 'direct'.
    # @param queue_opts [Hash] Opciones para la declaración de la cola (:durable, :auto_delete, etc.).
    # @param block [Boolean] Si es `true`, el hilo actual se bloqueará en el bucle de consumo.
    #   Útil para procesos worker dedicados.
    # @return [void]
    def subscribe(queue_name:, exchange_name:, routing_key:, exchange_type: 'direct', queue_opts: {}, block: true)
      x = session.exchange(name: exchange_name, type: exchange_type)
      q = session.queue(queue_name, queue_opts)
      q.bind(x, routing_key: routing_key)

      BugBunny.configuration.logger.info("[Consumer] Listening on #{queue_name} (Exchange: #{exchange_name})")

      start_health_check(queue_name)

      q.subscribe(manual_ack: true, block: block) do |delivery_info, properties, body|
        process_message(delivery_info, properties, body)
      end
    rescue StandardError => e
      BugBunny.configuration.logger.error("[Consumer] Error: #{e.message}. Retrying...")
      sleep BugBunny.configuration.network_recovery_interval
      retry
    end

    private

    # Procesa un mensaje entrante, invoca al controlador correspondiente y gestiona la respuesta RPC.
    #
    # El enrutamiento se basa en la propiedad `type` del mensaje AMQP (ej: 'users/create').
    # Si el mensaje requiere respuesta (`reply_to`), se envía el resultado de vuelta.
    #
    # @param delivery_info [Bunny::DeliveryInfo] Metadatos de la entrega (tag, redelivered, etc.).
    # @param properties [Bunny::MessageProperties] Propiedades del mensaje (headers, type, reply_to, correlation_id).
    # @param body [String] El payload del mensaje.
    # @return [void]
    def process_message(delivery_info, properties, body)
      if properties.type.nil? || properties.type.empty?
        BugBunny.configuration.logger.error("[Consumer] Missing 'type'. Rejected.")
        session.channel.reject(delivery_info.delivery_tag, false)
        return
      end

      route = parse_route(properties.type)

      headers = {
        type: properties.type,
        controller: route[:controller],
        action: route[:action],
        id: route[:id],
        content_type: properties.content_type,
        correlation_id: properties.correlation_id,
        reply_to: properties.reply_to
      }

      # Carga dinámica del controlador (Convention over Configuration)
      # Ej: 'users' -> Rabbit::Controllers::Users
      controller_class = "rabbit/controllers/#{route[:controller]}".camelize.constantize

      response_payload = controller_class.call(headers: headers, body: body)

      if properties.reply_to
        reply(response_payload, properties.reply_to, properties.correlation_id)
      end

      session.channel.ack(delivery_info.delivery_tag)
    rescue NameError => e
      BugBunny.configuration.logger.error("[Consumer] Controller not found: #{e.message}")
      session.channel.reject(delivery_info.delivery_tag, false)
    rescue StandardError => e
      BugBunny.configuration.logger.error("[Consumer] Error processing message: #{e.message}")
      session.channel.reject(delivery_info.delivery_tag, false)

      if properties.reply_to
        reply({ error: e.message }, properties.reply_to, properties.correlation_id)
      end
    end

    # Envía la respuesta RPC a la cola especificada en `reply_to`.
    #
    # @param payload [Hash, Array] Los datos a responder. Se serializarán a JSON.
    # @param reply_to [String] Nombre de la cola de respuesta (usualmente temporal).
    # @param correlation_id [String] ID para correlacionar la respuesta con el request original.
    def reply(payload, reply_to, correlation_id)
      session.channel.default_exchange.publish(
        payload.to_json,
        routing_key: reply_to,
        correlation_id: correlation_id,
        content_type: 'application/json'
      )
    end

    # Inicia una tarea en segundo plano para verificar periódicamente que la cola existe.
    # Esto ayuda a detectar desconexiones silenciosas o problemas de red.
    #
    # @param q_name [String] El nombre de la cola a monitorear.
    def start_health_check(q_name)
      Concurrent::TimerTask.new(execution_interval: 60) do
        session.channel.queue_declare(q_name, passive: true)
      rescue StandardError
        session.close
      end.execute
    end

    # Parsea la cadena de ruta (propiedad `type`) para extraer controlador, acción e ID.
    #
    # Soportes formatos:
    # * "controller/action"      -> { controller: "controller", action: "action", id: nil }
    # * "controller/id/action"   -> { controller: "controller", action: "action", id: "id" }
    #
    # @param route_string [String] La ruta recibida (ej: 'users/123/update').
    # @return [Hash] Hash con keys :controller, :action, :id.
    def parse_route(route_string)
      segments = route_string.split('/')
      controller = segments[0]
      action = 'index'
      id = nil

      case segments.length
      when 2 then action = segments[1]
      when 3
        id = segments[1]
        action = segments[2]
      end
      { controller: controller, action: action, id: id }
    end
  end
end
