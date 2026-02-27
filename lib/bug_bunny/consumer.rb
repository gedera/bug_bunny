# frozen_string_literal: true

require 'active_support/core_ext/string/inflections'
require 'concurrent'
require 'json'
require 'uri'
require 'cgi'
require 'rack/utils' # Necesario para parse_nested_query
require 'fileutils'  # Necesario para el touchfile del health check

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
    # @param exchange_opts [Hash] Opciones adicionales para el exchange (durable, auto_delete).
    # @param queue_opts [Hash] Opciones adicionales para la cola (durable, auto_delete).
    # @param block [Boolean] Si es `true`, bloquea el hilo actual (loop infinito).
    # @return [void]
    def subscribe(queue_name:, exchange_name:, routing_key:, exchange_type: 'direct', exchange_opts: {}, queue_opts: {}, block: true)
      # Declaración de Infraestructura
      x = session.exchange(name: exchange_name, type: exchange_type, opts: exchange_opts)
      q = session.queue(queue_name, queue_opts)
      q.bind(x, routing_key: routing_key)

      # 📊 LOGGING DE OBSERVABILIDAD: Calculamos las opciones finales para mostrarlas en consola
      final_x_opts = BugBunny::Session::DEFAULT_EXCHANGE_OPTIONS
                       .merge(BugBunny.configuration.exchange_options || {})
                       .merge(exchange_opts || {})
      final_q_opts = BugBunny::Session::DEFAULT_QUEUE_OPTIONS
                       .merge(BugBunny.configuration.queue_options || {})
                       .merge(queue_opts || {})

      BugBunny.configuration.logger.info("[BugBunny::Consumer] 🎧 Listening on '#{queue_name}' (Opts: #{final_q_opts})")
      BugBunny.configuration.logger.info("[BugBunny::Consumer] 🔀 Bounded to Exchange '#{exchange_name}' (#{exchange_type}) | Opts: #{final_x_opts} | RK: '#{routing_key}'")

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
    # Implementa un Router Heurístico que soporta namespaces y acciones custom
    # buscando dinámicamente el ID en la ruta mediante Regex y Fallback Semántico.
    #
    # @param method [String] Verbo HTTP (GET, POST, etc).
    # @param path [String] URL virtual del recurso (ej: 'foo/bar/algo/13/test').
    # @return [Hash] Estructura con keys {:controller, :action, :id, :params}.
    def router_dispatch(method, path)
      uri = URI.parse("http://dummy/#{path}")
      segments = uri.path.split('/').reject(&:empty?)

      query_params = uri.query ? Rack::Utils.parse_nested_query(uri.query) : {}
      if defined?(ActiveSupport::HashWithIndifferentAccess)
        query_params = query_params.with_indifferent_access
      end

      # 1. Acción Built-in: Health Check Global (/up o /api/up)
      if segments.last == 'up' && method.to_s.upcase == 'GET'
        ctrl = segments.size > 1 ? segments[0...-1].join('/') : 'application'
        return { controller: ctrl, action: 'up', id: nil, params: query_params }
      end

      # 2. Búsqueda dinámica del ID (Heurística por Regex)
      # Patrón: Enteros, UUIDs, o Hashes largos (Docker Swarm 25 chars, Mongo 24 chars)
      id_pattern = /^(?:\d+|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}|[a-zA-Z0-9_-]{20,})$/

      # FIX: Usamos rindex (de derecha a izquierda) para evitar falsos positivos con namespaces como 'v1'
      id_index = segments.rindex { |s| s.match?(id_pattern) }

      # 3. Fallback Semántico Posicional
      # Si el regex no detectó el ID (ej: ID corto como "node-1"), pero la semántica HTTP
      # indica que es una operación singular (PUT/DELETE/GET), asumimos que el último segmento es el ID.
      if id_index.nil? && segments.size >= 2
        last_segment = segments.last
        method_up = method.to_s.upcase

        is_member_verb = %w[PUT PATCH DELETE].include?(method_up)
        # En GET, nos aseguramos que la última palabra no sea una acción estándar de REST
        is_get_member = method_up == 'GET' && !%w[index new edit up action].include?(last_segment)

        if is_member_verb || is_get_member
          # Si tiene 3 o más segmentos (ej. nodes/node-1/stats), el ID no está al final.
          # Este fallback asume que para IDs raros, el formato clásico es recurso/id
          id_index = segments.size - 1
        end
      end

      # 4. Asignación de variables según escenario
      if id_index
        # ESCENARIO A: Ruta Miembro (ej. nodes/4bv445vgc158hk4twlxmdjo0v/stats)
        controller_name = segments[0...id_index].join('/')
        id = segments[id_index]
        action = segments[id_index + 1] # Puede ser nil si no hay acción extra al final
      else
        # ESCENARIO B: Ruta Colección (ej. api/v1/nodes)
        controller_name = segments.join('/')
        id = nil
        action = nil
      end

      # 5. Inferimos la acción clásica de Rails si no hay una explícita
      unless action
        action = case method.to_s.upcase
                 when 'GET' then id ? 'show' : 'index'
                 when 'POST' then 'create'
                 when 'PUT', 'PATCH' then 'update'
                 when 'DELETE' then 'destroy'
                 else id ? 'show' : 'index'
                 end
      end

      # 6. Inyectamos el ID en los parámetros para fácil acceso en el Controlador
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
    # Adicionalmente, si `health_check_file` está configurado, actualiza la
    # fecha de modificación (touch) de dicho archivo para notificar a orquestadores
    # externos (como Docker Swarm o Kubernetes) que el proceso está saludable.
    #
    # @param q_name [String] Nombre de la cola a monitorear.
    # @return [void]
    def start_health_check(q_name)
      file_path = BugBunny.configuration.health_check_file

      # Toque inicial para indicar al orquestador que el worker arrancó correctamente
      touch_health_file(file_path) if file_path

      Concurrent::TimerTask.new(execution_interval: BugBunny.configuration.health_check_interval) do
        # 1. Verificamos la salud de RabbitMQ (si falla, levanta un error y corta la ejecución del bloque)
        session.channel.queue_declare(q_name, passive: true)

        # 2. Si llegamos aquí, RabbitMQ y la cola están vivos. Avisamos al orquestador actualizando el archivo.
        touch_health_file(file_path) if file_path
      rescue StandardError => e
        BugBunny.configuration.logger.warn("[BugBunny::Consumer] ⚠️  Queue check failed: #{e.message}. Reconnecting session...")
        session.close
      end.execute
    end

    # Actualiza la fecha de modificación del archivo de health check (touchfile).
    # Se utiliza un `rescue` genérico para no interrumpir el flujo principal del worker
    # si el contenedor de Docker tiene problemas de permisos sobre la carpeta temporal.
    #
    # @param file_path [String] Ruta absoluta del archivo a tocar.
    # @return [void]
    def touch_health_file(file_path)
      FileUtils.touch(file_path)
    rescue StandardError => e
      BugBunny.configuration.logger.error("[BugBunny::Consumer] ⚠️  Cannot touch health check file '#{file_path}': #{e.message}")
    end
  end
end
