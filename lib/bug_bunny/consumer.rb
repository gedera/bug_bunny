require 'active_support/core_ext/string/inflections'
require 'concurrent'

module BugBunny
  class Consumer
    attr_reader :session

    # @param connection [Bunny::Session] Conexión activa (no del pool)
    def initialize(connection)
      @session = BugBunny::Session.new(connection)
    end

    def subscribe(queue_name:, exchange_name:, routing_key:, exchange_type: 'direct', queue_opts: {})
      x = session.exchange(name: exchange_name, type: exchange_type)
      q = session.queue(queue_name, queue_opts)
      q.bind(x, routing_key: routing_key)

      BugBunny.configuration.logger.info("[Consumer] Listening on #{queue_name}")

      start_health_check(queue_name)

      q.subscribe(manual_ack: true, block: true) do |delivery_info, properties, body|
        process_message(delivery_info, properties, body)
      end
    rescue StandardError => e
      BugBunny.configuration.logger.error("[Consumer] Error: #{e.message}. Retrying...")
      sleep BugBunny.configuration.network_recovery_interval
      retry
    end

    private

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

      controller_class = "rabbit/controllers/#{route[:controller]}".camelize.constantize
      response_payload = controller_class.call(headers: headers, body: body)

      if properties.reply_to
        reply(response_payload, properties.reply_to, properties.correlation_id)
      end

      session.channel.ack(delivery_info.delivery_tag)
    rescue StandardError => e
      BugBunny.configuration.logger.error("[Consumer] Error: #{e.message}")
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
