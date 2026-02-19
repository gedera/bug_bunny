# lib/bug_bunny/consumer.rb
require 'active_support/core_ext/string/inflections'
require 'concurrent'
require 'json'
require 'uri'
require 'cgi'
require 'rack/utils' # Necesario para parse_nested_query

module BugBunny
  # Consumidor de mensajes AMQP que actúa como un Router RESTful.
  #
  # Esta clase es el corazón del procesamiento de mensajes en el lado del servidor/worker.
  # Sus responsabilidades son:
  # 1. Escuchar una cola específica.
  # 2. Deserializar el mensaje y sus headers.
  # 3. Enrutar el mensaje a un Controlador (`BugBunny::Controller`) basándose en el "path" y el verbo HTTP.
  # 4. Gestionar el ciclo de respuesta RPC (Request-Response) para evitar timeouts en el cliente.
  #
  # @example Suscripción manual
  #   connection = BugBunny.create_connection
  #   BugBunny::Consumer.subscribe(
  #     connection: connection,
  #     queue_name: 'my_app_queue',
  #     exchange_name: 'my_exchange',
  #     routing_key: 'users.#'
  #   )
  class Consumer
    # @return [BugBunny::Session] La sesión wrapper de RabbitMQ que gestiona el canal.
    attr_reader :session

    # Método de conveniencia para instanciar y suscribir en un solo paso.
    #
    # @param connection [Bunny::Session] Una conexión TCP activa a RabbitMQ.
    # @param args [Hash] Argumentos que se pasarán al método {#subscribe}.
    # @return [BugBunny::Consumer] La instancia del consumidor creada.
    def self.subscribe(connection:, **args)
      new(connection).subscribe(**args)
    end

    # Inicializa un nuevo consumidor.
    #
    # @param connection [Bunny::Session] Conexión nativa de Bunny.
    def initialize(connection)
      @session = BugBunny::Session.new(connection)
    end

    # Inicia la suscripción a la cola y comienza el bucle de procesamiento.
    #
    # Declara el exchange y la cola (si no existen), realiza el "binding" y
    # se queda escuchando mensajes entrantes.
    #
    # @param queue_name [String] Nombre de la cola a escuchar.
    # @param exchange_name [String] Nombre del exchange al cual enlazar la cola.
    # @param routing_key [String] Patrón de enrutamiento (ej: 'users.*').
    # @param exchange_type [String] Tipo de exchange ('direct', 'topic', 'fanout').
    # @param queue_opts [Hash] Opciones adicionales para la cola (durable, auto_delete).
    # @param block [Boolean] Si es `true`, bloquea el hilo actual (loop infinito).
    # @return [void]
    def subscribe(queue_name:, exchange_name:, routing_key:, exchange_type: 'direct', queue_opts: {}, block: true)
      x = session.exchange(name: exchange_name, type: exchange_type)
      q = session.queue(queue_name, queue_opts)
      q.bind(x, routing_key: routing_key)

      BugBunny.configuration.logger.info("[BugBunny::Consumer] 🎧 Listening on '#{queue_name}' | Exchange: '#{exchange_name}' | Routing Key: '#{routing_key}'")
      start_health_check(queue_name)

      q.subscribe(manual_ack: true, block: block) do |delivery_info, properties, body|
        trace_id = properties.correlation_id

        logger = BugBunny.configuration.logger

        if logger.respond_to?(:tagged)
          logger.tagged(trace_id) { process_message(delivery_info, properties, body) }
        elsif defined?(Rails) && Rails.logger.respond_to?(:tagged)
          Rails.logger.tagged(trace_id) { process_message(delivery_info, properties, body) }
        else
          process_message(delivery_info, properties, body)
        end
      end
    rescue StandardError => e
      BugBunny.configuration.logger.error("[BugBunny::Consumer] 💥 Connection Error: #{e.message}. Retrying in #{BugBunny.configuration.network_recovery_interval}s...")
      sleep BugBunny.configuration.network_recovery_interval
      retry
    end

    private

    # Procesa un mensaje individual recibido de la cola.
    #
    # Realiza la orquestación completa: Parsing -> Routing -> Ejecución -> Respuesta.
    #
    # @param delivery_info [Bunny::DeliveryInfo] Metadatos de entrega (tag, redelivered, etc).
    # @param properties [Bunny::MessageProperties] Headers y propiedades AMQP (reply_to, correlation_id).
    # @param body [String] El payload crudo del mensaje.
    # @return [void]
    def process_message(delivery_info, properties, body)
      # 1. Validación de Headers
      path = properties.type || (properties.headers && properties.headers['path'])

      if path.nil? || path.empty?
        BugBunny.configuration.logger.error("[BugBunny::Consumer] ⛔ Rejected: Missing 'type' header.")
        session.channel.reject(delivery_info.delivery_tag, false)
        return
      end

      # 2. Recuperación Robusta del Verbo HTTP
      headers_hash = properties.headers || {}
      http_method = headers_hash['x-http-method'] || headers_hash['method'] || 'GET'

      # 3. Router: Inferencia de Controlador y Acción
      route_info = router_dispatch(http_method, path)

      BugBunny.configuration.logger.info("[BugBunny::Consumer] 📥 Started #{http_method} \"/#{path}\" for Routing Key: #{delivery_info.routing_key}")
      BugBunny.configuration.logger.debug("[BugBunny::Consumer] 📦 Body: #{body.truncate(200)}")

      request_metadata = {
        type: path,
        http_method: http_method,
        controller: route_info[:controller],
        action: route_info[:action],
        id: route_info[:id],
        query_params: route_info[:params],
        content_type: properties.content_type,
        correlation_id: properties.correlation_id,
        reply_to: properties.reply_to
      }.merge(properties.headers)

      # 4. Instanciación Dinámica del Controlador
      # Utilizamos el namespace configurado en lugar de hardcodear "Rabbit::Controllers"
      begin
        namespace = BugBunny.configuration.controller_namespace
        controller_name = route_info[:controller].camelize

        # Construcción: "Messaging::Handlers" + "::" + "Users"
        controller_class_name = "#{namespace}::#{controller_name}Controller"

        controller_class = controller_class_name.constantize

        unless controller_class < BugBunny::Controller
          raise BugBunny::SecurityError, "Class #{controller_class} is not a valid BugBunny Controller"
        end
      rescue NameError => _e
        BugBunny.configuration.logger.warn("[BugBunny::Consumer] ⚠️  Controller not found: #{controller_class_name} (Path: #{path})")
        handle_fatal_error(properties, 404, "Not Found", "Controller #{controller_class_name} not found")
        session.channel.reject(delivery_info.delivery_tag, false)
        return
      end

      # 5. Ejecución del Pipeline (Middleware + Acción)
      response_payload = controller_class.call(headers: request_metadata, body: body)

      # 6. Respuesta RPC
      if properties.reply_to
        reply(response_payload, properties.reply_to, properties.correlation_id)
      end

      # 7. Acknowledge
      session.channel.ack(delivery_info.delivery_tag)

    rescue StandardError => e
      BugBunny.configuration.logger.error("[BugBunny::Consumer] 💥 Execution Error (#{e.class}): #{e.message}")
      handle_fatal_error(properties, 500, "Internal Server Error", e.message)
      session.channel.reject(delivery_info.delivery_tag, false)
    end

    # Interpreta la URL y el verbo para decidir qué controlador ejecutar.
    #
    # Utiliza `Rack::Utils.parse_nested_query` para soportar parámetros anidados
    # como `q[service]=rabbit`.
    #
    # @param method [String] Verbo HTTP (GET, POST, etc).
    # @param path [String] URL virtual del recurso (ej: 'users/1?active=true').
    # @return [Hash] Estructura con keys {:controller, :action, :id, :params}.
    def router_dispatch(method, path)
      # Usamos URI para separar path de query string
      uri = URI.parse("http://dummy/#{path}")
      segments = uri.path.split('/').reject(&:empty?)

      # --- FIX: Uso de Rack para soportar params anidados ---
      query_params = uri.query ? Rack::Utils.parse_nested_query(uri.query) : {}

      # Si estamos en Rails, convertimos a HashWithIndifferentAccess para comodidad
      if defined?(ActiveSupport::HashWithIndifferentAccess)
        query_params = query_params.with_indifferent_access
      end

      # Lógica de Ruteo Convencional
      controller_name = segments[0]
      id = segments[1]

      action = case method.to_s.upcase
               when 'GET' then id ? 'show' : 'index'
               when 'POST' then 'create'
               when 'PUT', 'PATCH' then 'update'
               when 'DELETE' then 'destroy'
               else id || 'index'
               end

      # Soporte para rutas miembro custom (POST users/1/promote)
      if segments.size >= 3
         id = segments[1]
         action = segments[2]
      end

      # Inyectamos el ID en los params si existe en la ruta
      query_params['id'] = id if id

      { controller: controller_name, action: action, id: id, params: query_params }
    end

    # Envía una respuesta al cliente RPC utilizando Direct Reply-to.
    #
    # @param payload [Hash] Cuerpo de la respuesta ({ status: ..., body: ... }).
    # @param reply_to [String] Cola de respuesta (generalmente pseudo-cola amq.rabbitmq.reply-to).
    # @param correlation_id [String] ID para correlacionar la respuesta con la petición original.
    # @return [void]
    def reply(payload, reply_to, correlation_id)
      BugBunny.configuration.logger.debug("[BugBunny::Consumer] 📤 Sending RPC Reply to #{reply_to} | ID: #{correlation_id}")
      session.channel.default_exchange.publish(
        payload.to_json,
        routing_key: reply_to,
        correlation_id: correlation_id,
        content_type: 'application/json'
      )
    end

    # Maneja errores fatales asegurando que el cliente reciba una respuesta.
    # Evita que el cliente RPC se quede esperando hasta el timeout.
    #
    # @api private
    def handle_fatal_error(properties, status, error_title, detail)
      return unless properties.reply_to

      error_payload = {
        status: status,
        body: { error: error_title, detail: detail }
      }
      reply(error_payload, properties.reply_to, properties.correlation_id)
    end

    # Tarea de fondo (Heartbeat lógico) para verificar la salud del canal.
    # Si la cola desaparece o la conexión se cierra, fuerza una reconexión.
    #
    # @param q_name [String] Nombre de la cola a monitorear.
    def start_health_check(q_name)
      Concurrent::TimerTask.new(execution_interval: BugBunny.configuration.health_check_interval) do
        session.channel.queue_declare(q_name, passive: true)
      rescue StandardError
        BugBunny.configuration.logger.warn("[BugBunny::Consumer] ⚠️  Queue check failed. Reconnecting session...")
        session.close
      end.execute
    end
  end
end
