# frozen_string_literal: true

require 'active_support/core_ext/string/inflections'
require 'concurrent'
require_relative 'consumer/router'
require_relative 'consumer/response_handler'

module BugBunny
  # Consumidor de mensajes AMQP que actúa como un Router RESTful.
  # Orquesta la recepción del mensaje, el enrutamiento y la ejecución.
  class Consumer
    include Router
    include ResponseHandler

    # @return [BugBunny::Session] La sesión wrapper de RabbitMQ en uso.
    attr_reader :session

    # Método de conveniencia para instanciar y suscribir en un solo paso.
    # @param connection [Bunny::Session] Conexión activa.
    # @param args [Hash] Argumentos para {#subscribe}.
    def self.subscribe(connection:, **args)
      new(connection).subscribe(**args)
    end

    # @param connection [Bunny::Session] Conexión activa de Bunny.
    def initialize(connection)
      @session = BugBunny::Session.new(connection)
    end

    # Inicia la suscripción a la cola y el bucle de consumo.
    # @param queue_name [String] Nombre de la cola.
    # @param exchange_name [String] Nombre del exchange.
    # @param routing_key [String] Routing key.
    # @param options [Hash] Opciones adicionales (:exchange_type, :block).
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
