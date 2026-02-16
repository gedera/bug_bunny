# frozen_string_literal: true

require 'active_support/core_ext/string/inflections'
require 'concurrent'
require 'json'
require_relative 'consumer/router'

module BugBunny
  # Consumidor de mensajes AMQP que actúa como un Router RESTful.
  class Consumer
    include Router

    # @return [BugBunny::Session] La sesión wrapper de RabbitMQ en uso.
    attr_reader :session

    # Método de conveniencia para instanciar y suscribir en un solo paso.
    def self.subscribe(connection:, **args)
      new(connection).subscribe(**args)
    end

    # @param connection [Bunny::Session] Conexión activa de Bunny.
    def initialize(connection)
      @session = BugBunny::Session.new(connection)
    end

    # Inicia la suscripción a la cola y el bucle de consumo.
    def subscribe(queue_name:, exchange_name:, routing_key:, **options)
      queue = setup_topology(queue_name, exchange_name, routing_key, options)

      BugBunny.configuration.logger.info("[Consumer] Listening on #{queue_name} (Exchange: #{exchange_name})")
      start_health_check(queue_name)

      queue.subscribe(manual_ack: true, block: options.fetch(:block, true)) do |delivery_info, properties, body|
        process_message(delivery_info, properties, body)
      end
    rescue StandardError => e
      log_and_retry_connection(e)
    end

    private

    def setup_topology(queue_name, exchange_name, routing_key, options)
      ex_type = options.fetch(:exchange_type, 'direct')
      q_opts  = options.fetch(:queue_opts, {})

      x = session.exchange(name: exchange_name, type: ex_type)
      q = session.queue(queue_name, q_opts)
      q.bind(x, routing_key: routing_key)
      q
    end

    def process_message(delivery_info, properties, body)
      with_error_handling(delivery_info, properties) do
        validate_message_type!(delivery_info, properties)

        headers = extract_headers(properties)
        response = dispatch_request(headers, body)

        reply_if_needed(response, headers)
        session.channel.ack(delivery_info.delivery_tag)
      end
    end

    def with_error_handling(delivery_info, properties)
      yield
    rescue NameError => e
      handle_routing_error(delivery_info, properties, e)
    rescue StandardError => e
      handle_server_error(delivery_info, properties, e)
    end

    def validate_message_type!(delivery_info, properties)
      return unless properties.type.nil? || properties.type.empty?

      reject_message(delivery_info, 'Missing type header')
      raise BugBunny::Error, 'Message rejected due to missing type'
    end

    def extract_headers(properties)
      http_method = properties.headers ? (properties.headers['x-http-method'] || 'GET') : 'GET'
      route_info = router_dispatch(http_method, properties.type)

      route_info.merge(
        type: properties.type,
        http_method: http_method,
        content_type: properties.content_type,
        correlation_id: properties.correlation_id,
        reply_to: properties.reply_to
      )
    end

    def dispatch_request(headers, body)
      controller_class = "rabbit/controllers/#{headers[:controller]}".camelize.constantize
      controller_class.call(headers: headers, body: body)
    end

    def reply_if_needed(payload, headers)
      return unless headers[:reply_to]

      reply(payload, headers[:reply_to], headers[:correlation_id])
    end

    def reply(payload, reply_to, correlation_id)
      session.channel.default_exchange.publish(
        payload.to_json,
        routing_key: reply_to,
        correlation_id: correlation_id,
        content_type: 'application/json'
      )
    end

    def handle_routing_error(delivery_info, properties, error)
      BugBunny.configuration.logger.error("[Consumer] Routing Error: #{error.message}")
      handle_fatal_error(properties, 501, 'Routing Error', error.message)
      session.channel.reject(delivery_info.delivery_tag, false)
    end

    def handle_server_error(delivery_info, properties, error)
      BugBunny.configuration.logger.error("[Consumer] Execution Error: #{error.message}")
      handle_fatal_error(properties, 500, 'Internal Server Error', error.message)
      session.channel.reject(delivery_info.delivery_tag, false)
    end

    def handle_fatal_error(properties, status, error_title, detail)
      return unless properties.reply_to

      error_payload = { status: status, body: { error: error_title, detail: detail } }
      reply(error_payload, properties.reply_to, properties.correlation_id)
    end

    def reject_message(delivery_info, reason)
      BugBunny.configuration.logger.error("[Consumer] #{reason}. Message rejected.")
      session.channel.reject(delivery_info.delivery_tag, false)
    end

    def log_and_retry_connection(error)
      BugBunny.configuration.logger.error("[Consumer] Connection Error: #{error.message}. Retrying...")
      sleep BugBunny.configuration.network_recovery_interval
      retry
    end

    def start_health_check(q_name)
      Concurrent::TimerTask.new(execution_interval: BugBunny.configuration.health_check_interval) do
        session.channel.queue_declare(q_name, passive: true)
      rescue StandardError
        BugBunny.configuration.logger.warn('[Consumer] Queue check failed. Reconnecting session...')
        session.close
      end.execute
    end
  end
end
