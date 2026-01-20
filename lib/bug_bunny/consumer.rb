require 'active_support/core_ext/string/inflections'
require 'concurrent'
require 'json'

module BugBunny
  class Consumer
    attr_reader :session

    # === 1. NUEVO: Wrapper de Clase (Fachada) ===
    # Permite llamar a BugBunny::Consumer.subscribe(connection: conn, ...)
    def self.subscribe(connection:, **args)
      new(connection).subscribe(**args)
    end
    # ============================================

    # @param connection [Bunny::Session] Conexión activa (no del pool)
    def initialize(connection)
      @session = BugBunny::Session.new(connection)
    end

    def subscribe(queue_name:, exchange_name:, routing_key:, exchange_type: 'direct', queue_opts: {}, block: true)
      # 1. Declarar Exchange y Cola
      x = session.exchange(name: exchange_name, type: exchange_type)

      # queue_opts permite pasar { auto_delete: true, exclusive: false, etc }
      q = session.queue(queue_name, queue_opts)

      # 2. Bind (Atar cola al exchange)
      q.bind(x, routing_key: routing_key)

      BugBunny.configuration.logger.info("[Consumer] Listening on #{queue_name} (Exchange: #{exchange_name})")

      # 3. Health Check (Opcional, mantiene viva la conexión)
      start_health_check(queue_name)

      # 4. Suscripción
      # block: true es VITAL para que el Rake task no termine inmediatamente.
      q.subscribe(manual_ack: true, block: block) do |delivery_info, properties, body|
        process_message(delivery_info, properties, body)
      end
    rescue StandardError => e
      BugBunny.configuration.logger.error("[Consumer] Error: #{e.message}. Retrying...")
      sleep BugBunny.configuration.network_recovery_interval
      retry
    end

    private

    def process_message(delivery_info, properties, body)
      # ... (Tu lógica existente de parse_route, constantize, ack, reply) ...
      # Se mantiene idéntica a la que me pasaste antes.
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

      # Asumimos que los controladores están en Rabbit::Controllers::Nombre
      controller_class = "rabbit/controllers/#{route[:controller]}".camelize.constantize

      # Invocamos al controlador
      response_payload = controller_class.call(headers: headers, body: body)

      # RPC: Si esperan respuesta, respondemos
      if properties.reply_to
        reply(response_payload, properties.reply_to, properties.correlation_id)
      end

      session.channel.ack(delivery_info.delivery_tag)

    rescue NameError => e
      BugBunny.configuration.logger.error("[Consumer] Controller not found: #{e.message}")
      session.channel.reject(delivery_info.delivery_tag, false) # No reencolar si no existe el código
    rescue StandardError => e
      BugBunny.configuration.logger.error("[Consumer] Error processing message: #{e.message}")
      session.channel.reject(delivery_info.delivery_tag, false)

      if properties.reply_to
        reply({ error: e.message }, properties.reply_to, properties.correlation_id)
      end
    end

    def reply(payload, reply_to, correlation_id)
      session.channel.default_exchange.publish(
        payload.to_json,
        routing_key: reply_to,
        correlation_id: correlation_id,
        content_type: 'application/json'
      )
    end

    def start_health_check(q_name)
      Concurrent::TimerTask.new(execution_interval: 60) do
        session.channel.queue_declare(q_name, passive: true)
      rescue StandardError
        session.close
      end.execute
    end

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
