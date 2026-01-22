# lib/bug_bunny/consumer.rb
require 'active_support/core_ext/string/inflections'
require 'concurrent'
require 'json'
require 'uri'
require 'cgi'

module BugBunny
  # Consumidor de mensajes y Router RPC.
  #
  # Esta clase escucha en una cola RabbitMQ, parsea el header `type` como si fuera una URL,
  # extrae el controlador, acción, ID y query params, y despacha la ejecución al controlador correspondiente.
  class Consumer
    attr_reader :session

    # Método factory para instanciar y suscribir.
    # @see #subscribe
    def self.subscribe(connection:, **args)
      new(connection).subscribe(**args)
    end

    def initialize(connection)
      @session = BugBunny::Session.new(connection)
    end

    # Inicia la suscripción a la cola.
    #
    # @param queue_name [String] Cola a escuchar.
    # @param exchange_name [String] Exchange para binding.
    # @param routing_key [String] Routing key.
    # @param exchange_type [String] Tipo de exchange.
    # @param block [Boolean] Bloquear el hilo principal (loop).
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
    #
    # 1. Parsea la "URL" del header `type`.
    # 2. Instancia el controlador dinámicamente.
    # 3. Ejecuta la acción.
    # 4. Envía respuesta RPC si `reply_to` está presente.
    def process_message(delivery_info, properties, body)
      if properties.type.nil? || properties.type.empty?
        BugBunny.configuration.logger.error("[Consumer] Missing 'type'. Rejected.")
        session.channel.reject(delivery_info.delivery_tag, false)
        return
      end

      # Parseo robusto de la URL (Path + Query Params)
      route_info = parse_route(properties.type)

      headers = {
        type: properties.type,
        controller: route_info[:controller],
        action: route_info[:action],
        id: route_info[:id],            # ID extraído del path (ej: /users/show/12)
        query_params: route_info[:params], # Hash de query params (ej: ?active=true)
        content_type: properties.content_type,
        correlation_id: properties.correlation_id,
        reply_to: properties.reply_to
      }

      # Convention: "users" -> Rabbit::Controllers::UsersController (o namespace configurable)
      controller_class_name = "rabbit/controllers/#{route_info[:controller]}".camelize
      controller_class = controller_class_name.constantize

      response_payload = controller_class.call(headers: headers, body: body)

      if properties.reply_to
        reply(response_payload, properties.reply_to, properties.correlation_id)
      end

      session.channel.ack(delivery_info.delivery_tag)
    rescue NameError => e
      BugBunny.configuration.logger.error("[Consumer] Controller not found for route '#{properties.type}': #{e.message}")
      session.channel.reject(delivery_info.delivery_tag, false)
    rescue StandardError => e
      BugBunny.configuration.logger.error("[Consumer] Execution Error: #{e.message}")
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

    # Analiza el string `type` como una URL.
    #
    # Soporta:
    # * `users/index?active=true` -> {controller: users, action: index, params: {active: true}}
    # * `users/show/12`           -> {controller: users, action: show, id: 12}
    # * `users/update/12`         -> {controller: users, action: update, id: 12}
    #
    # @param route_string [String] El valor del header type.
    # @return [Hash] Keys: :controller, :action, :id, :params.
    def parse_route(route_string)
      # Anteponemos un host dummy para usar URI estándar con paths relativos
      uri = URI.parse("http://dummy/#{route_string}")
      # 1. Query Params (?foo=bar)
      query_params = uri.query ? CGI.parse(uri.query).transform_values(&:first) : {}

      # 2. Path Segments (/users/show/12)
      segments = uri.path.split('/').reject(&:empty?)

      controller = segments[0] # "users"
      action = segments[1]     # "index", "show", "update"
      id = segments[2]         # "12" (opcional)

      # Inyectamos el ID en los params si existe en la ruta para facilitar acceso unificado
      query_params['id'] = id if id

      {
        controller: controller,
        action: action || 'index',
        id: id,
        params: query_params
      }
    end
  end
end
