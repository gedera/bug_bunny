# frozen_string_literal: true

require 'active_support/core_ext/string/inflections'
require 'concurrent'
require 'json'
require 'uri'
require 'cgi'
require 'rack/utils'

module BugBunny
  # Consumidor de mensajes AMQP que actúa como un Router RESTful.
  #
  # Escucha una cola, deserializa los mensajes y los despacha a controladores
  # basándose en el header 'type' (URL) y 'x-http-method'.
  # También gestiona la respuesta RPC (Direct Reply-to) y el manejo de errores.
  class Consumer
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
    # Declara el exchange y la cola si no existen (idempotente).
    #
    # @param queue_name [String] Nombre de la cola a escuchar.
    # @param exchange_name [String] Nombre del exchange a enlazar.
    # @param routing_key [String] Routing key para el binding.
    # @param options [Hash] Opciones adicionales de configuración.
    # @option options [String] :exchange_type ('direct') Tipo de exchange.
    # @option options [Hash] :queue_opts ({}) Opciones de la cola (durable, etc).
    # @option options [Boolean] :block (true) Si debe bloquear el thread actual.
    #
    # @return [void]
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

    # Configura exchange, cola y binding.
    # Extraído para reducir AbcSize de subscribe.
    def setup_topology(queue_name, exchange_name, routing_key, options)
      ex_type = options.fetch(:exchange_type, 'direct')
      q_opts  = options.fetch(:queue_opts, {})

      x = session.exchange(name: exchange_name, type: ex_type)
      q = session.queue(queue_name, q_opts)
      q.bind(x, routing_key: routing_key)
      q
    end

    # Lógica principal de procesamiento de cada mensaje.
    # Utiliza un bloque wrapper para el manejo de errores y mantiene el flujo lineal.
    def process_message(delivery_info, properties, body)
      with_error_handling(delivery_info, properties) do
        validate_message_type!(delivery_info, properties)

        headers = extract_headers(properties)
        response = dispatch_request(headers, body)

        reply_if_needed(response, headers)
        session.channel.ack(delivery_info.delivery_tag)
      end
    end

    # Wrapper para encapsular la lógica de rescate de errores.
    # Reduce drásticamente la complejidad y longitud de process_message.
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
      raise BugBunny::Error, 'Message rejected due to missing type' # Interrumpe el flujo
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

    # Parsea la URL virtual para determinar controlador, acción y parámetros.
    # Refactorizado para reducir complejidad ciclomática y AbcSize.
    def router_dispatch(method, path)
      uri = URI.parse("http://dummy/#{path}")
      segments = parse_path_segments(uri.path)

      # Determinamos controlador, id y acción
      route = resolve_route_segments(method, segments)

      # Construimos los parámetros finales
      build_route_params(uri, route)
    end

    def parse_path_segments(path)
      path.split('/').reject(&:empty?)
    end

    # Resuelve la ruta basándose en los segmentos y el verbo HTTP.
    def resolve_route_segments(method, segments)
      controller = segments[0]
      id = segments[1]
      action = segments[2] # Soporte para rutas miembro /controller/id/action

      # Si no hay acción explícita en la URL, la inferimos
      action ||= determine_rest_action(method, id)

      { controller: controller, action: action, id: id }
    end

    def determine_rest_action(method, id)
      case method.to_s.upcase
      when 'GET'            then id ? 'show' : 'index'
      when 'POST'           then 'create'
      when 'PUT', 'PATCH'   then 'update'
      when 'DELETE'         then 'destroy'
      else id || 'index'
      end
    end

    def build_route_params(uri, route)
      query_params = parse_query_params(uri.query)
      query_params['id'] = route[:id] if route[:id]

      {
        controller: route[:controller],
        action: route[:action],
        id: route[:id],
        params: query_params
      }
    end

    def parse_query_params(query_string)
      params = query_string ? Rack::Utils.parse_nested_query(query_string) : {}
      defined?(ActiveSupport::HashWithIndifferentAccess) ? params.with_indifferent_access : params
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
