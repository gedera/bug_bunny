# lib/bug_bunny/consumer.rb
require 'active_support/core_ext/string/inflections'
require 'concurrent'
require 'json'
require 'uri'
require 'cgi'

module BugBunny
  # Consumidor de mensajes y Router RPC estilo REST.
  #
  # Parsea el header `type` (URL) y el header `x-http-method` (Verbo)
  # para despachar al controlador y acción correctos siguiendo convenciones Rails.
  class Consumer
    attr_reader :session

    def self.subscribe(connection:, **args)
      new(connection).subscribe(**args)
    end

    def initialize(connection)
      @session = BugBunny::Session.new(connection)
    end

    # Inicia la suscripción a la cola.
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
      BugBunny.configuration.logger.error("[Consumer] Connection Error: #{e.message}. Retrying...")
      sleep BugBunny.configuration.network_recovery_interval
      retry
    end

    private

    # Procesa el mensaje entrante.
    # Infiere la acción basándose en Verbo + URL.
    def process_message(delivery_info, properties, body)
      if properties.type.nil? || properties.type.empty?
        BugBunny.configuration.logger.error("[Consumer] Missing 'type'. Rejected.")
        session.channel.reject(delivery_info.delivery_tag, false)
        return
      end

      # 1. Leemos el verbo HTTP desde el header (Default: GET)
      # Nota: Bunny devuelve los headers en propiedades.headers
      http_method = properties.headers ? (properties.headers['x-http-method'] || 'GET') : 'GET'

      # 2. Despachamos usando lógica Rails
      route_info = router_dispatch(http_method, properties.type)

      headers = {
        type: properties.type,
        http_method: http_method,
        controller: route_info[:controller],
        action: route_info[:action],
        id: route_info[:id],
        query_params: route_info[:params],
        content_type: properties.content_type,
        correlation_id: properties.correlation_id,
        reply_to: properties.reply_to
      }

      # Convention: "users" -> Rabbit::Controllers::UsersController
      controller_class_name = "rabbit/controllers/#{route_info[:controller]}".camelize
      controller_class = controller_class_name.constantize

      response_payload = controller_class.call(headers: headers, body: body)

      if properties.reply_to
        reply(response_payload, properties.reply_to, properties.correlation_id)
      end

      session.channel.ack(delivery_info.delivery_tag)
    rescue NameError => e
      BugBunny.configuration.logger.error("[Consumer] Controller/Action not found: #{e.message}")
      session.channel.reject(delivery_info.delivery_tag, false)
    rescue StandardError => e
      BugBunny.configuration.logger.error("[Consumer] Execution Error: #{e.message}")
      session.channel.reject(delivery_info.delivery_tag, false)
      if properties.reply_to
        reply({ error: e.message }, properties.reply_to, properties.correlation_id)
      end
    end

    # Router: Simula el config/routes.rb de Rails.
    #
    # @param method [String] Verbo HTTP (GET, POST, etc).
    # @param path [String] URL Path (ej: 'users/1').
    # @return [Hash] {controller, action, id, params}
    def router_dispatch(method, path)
      uri = URI.parse("http://dummy/#{path}")
      segments = uri.path.split('/').reject(&:empty?) # ["users", "123"]
      query_params = uri.query ? CGI.parse(uri.query).transform_values(&:first) : {}

      controller_name = segments[0] # "users"
      id = segments[1]              # "123" o nil

      # Lógica de Inferencia Rails Standard
      # GET users      -> index
      # GET users/1    -> show
      # POST users     -> create
      # PUT users/1    -> update
      # DELETE users/1 -> destroy
      action = case method.to_s.upcase
               when 'GET'
                 id ? 'show' : 'index'
               when 'POST'
                 'create'
               when 'PUT', 'PATCH'
                 'update'
               when 'DELETE'
                 'destroy'
               else
                 id || 'index' # Fallback para verbos custom
               end

      # Soporte para Member Actions Custom (ej: POST users/1/activate)
      # Path: users/1/activate -> segments: [users, 1, activate]
      if segments.size >= 3
         id = segments[1]
         action = segments[2]
      end

      # Inyectar ID en params para acceso unificado en el controller
      query_params['id'] = id if id

      {
        controller: controller_name,
        action: action,
        id: id,
        params: query_params
      }
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
  end
end
