# host: Especifica la dirección de red (hostname o IP) donde se está ejecutando el servidor RabbitMQ.
# username: El nombre de usuario que se utiliza para la autenticación.
# password: La contraseña para la autenticación.
# vhost: Define el Virtual Host (VHost) al que se conectará la aplicación. Un VHost actúa como un namespace virtual dentro del broker, aislando entornos y recursos.
# logger: Indica a Bunny que use el sistema de logging estándar de Rails, integrando los mensajes del cliente AMQP con el resto de los logs de tu aplicación.
#
# Resiliencia y Recuperación Automática
#
# Estos parámetros son fundamentales para manejar fallos de red y garantizar que la aplicación se recupere sin intervención manual.
# automatically_recover: Indica al cliente Bunny que debe intentar automáticamente reestablecer la conexión y todos los recursos asociados (canales, colas, exchanges) si la conexión se pierde debido a un fallo de red o un reinicio del broker. Nota: Este parámetro puede entrar en conflicto con un bucle de retry manual).
# network_recovery_interval: El tiempo que Bunny esperará entre intentos consecutivos de reconexión de red.
# heartbeat: El intervalo de tiempo (en segundos) en el que el cliente y el servidor deben enviarse un pequeño paquete ("latido"). Si no se recibe un heartbeat durante dos intervalos consecutivos, se asume que la conexión ha muerto (generalmente por un fallo de red o un proceso colgado), lo que dispara el mecanismo de recuperación.
#
# Tiempos de Espera (Timeouts)
#
# Estos parámetros previenen que la aplicación se bloquee indefinidamente esperando una respuesta del servidor.
# connection_timeout: Tiempo máximo (en segundos) que Bunny esperará para establecer la conexión TCP inicial con el servidor RabbitMQ.
# read_timeout: Tiempo máximo (en segundos) que la conexión esperará para leer datos del socket. Si el servidor se queda en silencio por más de 30 segundos, el socket se cerrará.
# write_timeout: Tiempo máximo (en segundos) que la conexión esperará para escribir datos en el socket. Útil para manejar escenarios donde la red es lenta o está congestionada.
# continuation_timeout: Es un timeout interno de protocolo AMQP (dado en milisegundos). Define cuánto tiempo esperará el cliente para que el servidor responda a una operación que requiere múltiples frames o pasos (como una transacción o una confirmación compleja). En este caso, son 15 segundos.
module BugBunny
  class Rabbit
    include ActiveModel::Model
    include ActiveModel::Attributes

    DEFAULT_EXCHANGE_OPTIONS = { durable: false, auto_delete: false }.freeze

    # DEFAULT_MAX_PRIORITY = 10

    DEFAULT_QUEUE_OPTIONS = {
      exclusive: false,
      durable: false,
      auto_delete: true,
      # arguments: { 'x-max-priority' => DEFAULT_MAX_PRIORITY }
    }.freeze

    attr_accessor :connection, :queue, :exchange

    def channel
      @channel_mutex ||= Mutex.new
      return @channel if @channel&.open?

      @channel_mutex.synchronize do
        return @channel if @channel&.open?

        @channel = connection.create_channel
        @channel.confirm_select
        @channel.prefetch(RABBIT_CHANNEL_PREFETCH) # Limita mensajes concurrentes por consumidor
        @channel
      end
    end

    def build_exchange(name: nil, type: 'direct', opts: {})
      return @exchange if defined?(@exchange)

      exchange_options = DEFAULT_EXCHANGE_OPTIONS.merge(opts.compact)

      if name.blank?
        @exchange = channel.default_exchange
        return @exchange
      end

      Rails.logger.info("ExchangeName: #{name}, ExchangeType: #{type}, opts: #{opts}")

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

    def build_queue(name: '', opts: {})
      name = name.to_s
      queue_options = DEFAULT_QUEUE_OPTIONS.merge(opts.compact)
      Rails.logger.info("QueueName: #{name}, opts: #{queue_options}")
      @queue = channel.queue(name, queue_options)
    end

    def publish!(msg, opts)
      options = default_publish_options.merge(opts.compact)

      msg = msg.instance_of?(Hash) ? msg.to_json : msg.to_s

      Rails.logger.info("Message: #{msg}")
      Rails.logger.info("Options: #{options}")

      exchange.publish(msg, options)
      # channel.wait_for_confirms # Esto solo confirma que el mensaje llego el exchange
    rescue Bunny::Exception => e
      Rails.logger.error(e)
      raise BugBunny::PublishError, e
    end

    def publish_and_consume!(msg, opts)
      options = default_publish_options.merge(opts.compact)

      response_latch = Concurrent::CountDownLatch.new(1)
      response = nil

      reply_queue = channel.queue('', exclusive: true, durable: false, auto_delete: true)
      options[:reply_to] = reply_queue.name

      subscription = reply_queue.subscribe(manual_ack: true, block: false) do |delivery_info, properties, body|
        Rails.logger.debug("CONSUMER DeliveryInfo: #{delivery_info}")
        Rails.logger.debug("CONSUMER Properties: #{properties}")
        Rails.logger.debug("CONSUMER Body: #{body}")
        if properties.correlation_id == options[:correlation_id]
          response = ActiveSupport::JSON.decode(body).deep_symbolize_keys.with_indifferent_access
          channel.ack(delivery_info.delivery_tag)
          response_latch.count_down
        else
          Rails.logger.debug('Correlation_id not match')
          # Si el correlation_id no coincide, rechazamos el mensaje para que RabbitMQ lo maneje
          channel.reject(delivery_info.delivery_tag, false)
        end
      end

      Rails.logger.debug("PUBLISHER Message: #{msg}")
      Rails.logger.debug("PUBLISHER Options: #{options}")
      publish!(msg, options)

      if response_latch.wait(RABBIT_CONNECTION_TIMEOUT)
        subscription.cancel
        build_response(status: response[:status], body: response[:body])
      else
        raise "Timeout: No response received within #{RABBIT_CONNECTION_TIMEOUT} seconds."
      end
    rescue BugBunny::ResponseError::Base => e
      subscription&.cancel
      raise e
    rescue RuntimeError => e
      subscription&.cancel
      Rails.logger.error("[Rabbit] Error in publish_and_consume: #{e.class} - <#{e.message}>")
      raise(BugBunny::ResponseError::RequestTimeout, e.message) if e.message.include?('Timeout')

      raise BugBunny::ResponseError::InternalServerError, e.message
    rescue StandardError => e
      subscription&.cancel
      Rails.logger.error("[Rabbit] Error in publish_and_consume: #{e.class} - <#{e.message}>")
      raise e
    end

    def parse_route(route)
      # De momento no resuelve anidado
      segments = route.split('/')
      controller_name = segments[0]
      action_name = 'index'
      id = nil

      case segments.length
      when 2
        # Patrón: controller/action (Ej: 'secrets/index', 'swarm/info')
        action_name = segments[1]
      when 3
        # Patrón: controller/id/action (Ej: 'secrets/123/update', 'services/999/destroy')
        id = segments[1]
        action_name = segments[2]
      end

      { controller: controller_name, action: action_name, id: id }
    end

    def consume!
      queue.subscribe(manual_ack: true, block: true) do |delivery_info, properties, body|
        Rails.logger.debug("DeliveryInfo: #{delivery_info}")
        Rails.logger.debug("Properties: #{properties}")
        Rails.logger.debug("Body: #{body}")

        raise StandardError, 'Undefined properties.type' if properties.type.blank?

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

        controller = "rabbit/controllers/#{route[:controller]}".camelize.constantize
        response_payload = controller.call(headers: headers, body: body)

        Rails.logger.debug("Response: #{response_payload}")

        if properties.reply_to.present?
          Rails.logger.info("Sending response to #{properties.reply_to}")

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
        Rails.logger.error(e)
        channel.reject(delivery_info.delivery_tag, false)
      rescue NameError => e # Controller no exist
        Rails.logger.error(e)
        channel.reject(delivery_info.delivery_tag, false)
      rescue StandardError => e
        Rails.logger.error("Error processing message: #{e.message} (#{e.class})")
        # Reject the message and do NOT re-queue it immediately.
        channel.reject(delivery_info.delivery_tag, false)
      end
    end

    # El success y el error es para tener compatibilidad con el bug_bunny
    def build_response(status:, body:)
      case status
      when 'success' then body # Old compatibility
      when 'error' then raise BugBunny::ResponseError::InternalServerError, body # Old compatibility
      when 200, 201 then body
      when 204 then nil
      when 400 then raise BugBunny::ResponseError::BadRequest, body.to_json
      when 404 then raise BugBunny::ResponseError::NotFound
      when 406 then raise BugBunny::ResponseError::NotAcceptable
      when 422 then raise BugBunny::ResponseError::UnprocessableEntity, body.to_json
      when 500 then raise BugBunny::ResponseError::InternalServerError, body.to_json
      else
        raise BugBunny::ResponseError::Base, body.to_json
      end
    end

    def self.run_consumer(connection:, exchange:, exchange_type:, queue_name:, routing_key:, queue_opts: {})
      app = new(connection: connection)
      app.build_exchange(name: exchange, type: exchange_type)
      app.build_queue(name: queue_name, opts: queue_opts)
      app.queue.bind(app.exchange, routing_key: routing_key)
      app.consume!
      health_check_thread = start_health_check(app, queue_name: queue_name, exchange_name: exchange, exchange_type: exchange_type)
      health_check_thread.wait_for_termination
      raise 'Health check error: Forcing reconnect.'
    rescue StandardError => e
      # Esto lo pongo por que si levanto el rabbit y el consumer a la vez
      # El rabbit esta una banda de tiempo hasta aceptar conexiones, por lo que
      # el consumer explota 2 millones de veces, por lo tanto con esto hago
      # la espera ocupada y me evito de ponerlo en el entrypoint-docker
      Rails.logger.error("[RABBIT] Consumer error: #{e.message} (#{e.class})")
      Rails.logger.debug("[RABBIT] Consumer error: #{e.backtrace}")
      connection&.close
      sleep RABBIT_NETWORK_RECOVERY
      retry
    end

    def self.start_health_check(app, queue_name:, exchange_name:, exchange_type:)
      task = Concurrent::TimerTask.new(execution_interval: RABBIT_HEALT_CHECK) do
        # con esto veo si el exachange o la cola no la borraron desde la vista de rabbit
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

    def self.create_connection(host: nil, username: nil, password: nil, vhost: nil)
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
    end
  end
end
