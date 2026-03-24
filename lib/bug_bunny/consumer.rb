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
  # 3. Consultar el mapa global `BugBunny.routes` para enrutar el mensaje a un Controlador.
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
    include BugBunny::Observability

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
      @session = BugBunny::Session.new(connection, publisher_confirms: false)
      @health_timer = nil
      @logger = BugBunny.configuration.logger
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
      attempt = 0

      begin
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

        safe_log(:info, "consumer.start", queue: queue_name, queue_opts: final_q_opts)
        safe_log(:info, "consumer.bound", exchange: exchange_name, exchange_type: exchange_type, routing_key: routing_key, exchange_opts: final_x_opts)

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
        attempt += 1
        max_attempts = BugBunny.configuration.max_reconnect_attempts

        if max_attempts && attempt >= max_attempts
          safe_log(:error, "consumer.reconnect_exhausted", max_attempts_count: max_attempts, **exception_metadata(e))
          raise
        end

        wait = [
          BugBunny.configuration.network_recovery_interval * (2 ** (attempt - 1)),
          BugBunny.configuration.max_reconnect_interval
        ].min

        safe_log(:error, "consumer.connection_error", attempt_count: attempt, max_attempts_count: max_attempts || 'infinity', retry_in_s: wait, **exception_metadata(e))
        sleep wait
        retry
      end
    end

    private

    # Procesa un mensaje individual recibido de la cola orquestando el ruteo declarativo.
    #
    # Realiza la orquestación completa: Parsing -> Reconocimiento de Ruta -> Ejecución -> Respuesta.
    #
    # @param delivery_info [Bunny::DeliveryInfo] Metadatos de entrega (tag, redelivered, etc).
    # @param properties [Bunny::MessageProperties] Headers y propiedades AMQP (reply_to, correlation_id).
    # @param body [String] El payload crudo del mensaje.
    # @return [void]
    def process_message(delivery_info, properties, body)
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # 1. Validación de Headers (URL path)
      path = properties.type || (properties.headers && properties.headers['path'])

      if path.nil? || path.empty?
        safe_log(:error, "consumer.message_rejected", reason: :missing_type_header)
        session.channel.reject(delivery_info.delivery_tag, false)
        return
      end

      # 2. Recuperación Robusta del Verbo HTTP
      headers_hash = properties.headers || {}
      http_method = (headers_hash['x-http-method'] || headers_hash['method'] || 'GET').to_s.upcase

      safe_log(:info, "consumer.message_received", method: http_method, path: path, routing_key: delivery_info.routing_key)
      safe_log(:debug, "consumer.message_received_body", body: body.truncate(200))

      # ===================================================================
      # 3. Ruteo Declarativo
      # ===================================================================
      uri = URI.parse("http://dummy/#{path}")

      # Extraemos query params (ej. /nodes?status=active)
      query_params = uri.query ? Rack::Utils.parse_nested_query(uri.query) : {}
      if defined?(ActiveSupport::HashWithIndifferentAccess)
        query_params = query_params.with_indifferent_access
      end

      # Le preguntamos al motor de rutas global quién debe manejar esto
      route_info = BugBunny.routes.recognize(http_method, uri.path)

      if route_info.nil?
        safe_log(:warn, "consumer.route_not_found", method: http_method, path: uri.path)
        handle_fatal_error(properties, 404, "Not Found", "No route matches [#{http_method}] \"/#{uri.path}\"")
        session.channel.reject(delivery_info.delivery_tag, false)
        return
      end

      # Fusionamos los parámetros extraídos de la URL (ej. :id) con los query_params
      final_params = query_params.merge(route_info[:params])

      # ===================================================================
      # 4. Instanciación del Controlador
      # ===================================================================
      namespace = BugBunny.configuration.controller_namespace
      controller_name = route_info[:controller].camelize
      controller_class_name = "#{namespace}::#{controller_name}Controller"

      begin
        controller_class = controller_class_name.constantize
      rescue NameError
        safe_log(:warn, "consumer.controller_not_found", controller: controller_class_name)
        handle_fatal_error(properties, 404, "Not Found", "Controller #{controller_class_name} not found")
        session.channel.reject(delivery_info.delivery_tag, false)
        return
      end

      # Verificación estricta de Seguridad (RCE Prevention)
      unless controller_class < BugBunny::Controller
        safe_log(:error, "consumer.security_violation", reason: :invalid_controller, controller: controller_class)
        handle_fatal_error(properties, 403, "Forbidden", "Invalid Controller Class")
        session.channel.reject(delivery_info.delivery_tag, false)
        return
      end

      safe_log(:debug, "consumer.route_matched", controller: controller_class_name, action: route_info[:action])

      request_metadata = {
        type: path,
        http_method: http_method,
        controller: route_info[:controller],
        action: route_info[:action],
        id: final_params['id'] || final_params[:id],
        query_params: final_params,
        content_type: properties.content_type,
        correlation_id: properties.correlation_id,
        reply_to: properties.reply_to
      }.merge(headers_hash)

      # ===================================================================
      # 5. Ejecución y Respuesta
      # ===================================================================
      response_payload = controller_class.call(headers: request_metadata, body: body)

      if properties.reply_to
        reply(response_payload, properties.reply_to, properties.correlation_id)
      end

      session.channel.ack(delivery_info.delivery_tag)

      safe_log(:info, "consumer.message_processed",
               status: response_payload[:status],
               duration_s: duration_s(start_time),
               controller: controller_class_name,
               action: route_info[:action])

    rescue StandardError => e
      safe_log(:error, "consumer.execution_error", duration_s: duration_s(start_time), **exception_metadata(e))
      safe_log(:debug, "consumer.execution_error_backtrace", backtrace: e.backtrace.first(5).join(' | '))
      handle_fatal_error(properties, 500, "Internal Server Error", e.message)
      session.channel.reject(delivery_info.delivery_tag, false)
    end

    # Envía una respuesta al cliente RPC utilizando Direct Reply-to.
    #
    # @param payload [Hash] Cuerpo de la respuesta ({ status: ..., body: ... }).
    # @param reply_to [String] Cola de respuesta (generalmente pseudo-cola amq.rabbitmq.reply-to).
    # @param correlation_id [String] ID para correlacionar la respuesta con la petición original.
    # @return [void]
    def reply(payload, reply_to, correlation_id)
      safe_log(:debug, "consumer.rpc_reply", reply_to: reply_to, correlation_id: correlation_id)
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
      # Detener el timer anterior antes de crear uno nuevo (evita leak en cada retry)
      @health_timer&.shutdown
      @health_timer = nil

      file_path = BugBunny.configuration.health_check_file

      # Toque inicial para indicar al orquestador que el worker arrancó correctamente
      touch_health_file(file_path) if file_path

      @health_timer = Concurrent::TimerTask.new(execution_interval: BugBunny.configuration.health_check_interval) do
        # 1. Verificamos la salud de RabbitMQ (si falla, levanta un error y corta la ejecución del bloque)
        session.channel.queue_declare(q_name, passive: true)

        # 2. Si llegamos aquí, RabbitMQ y la cola están vivos. Avisamos al orquestador actualizando el archivo.
        touch_health_file(file_path) if file_path
      rescue StandardError => e
        safe_log(:warn, "consumer.health_check_failed", queue: q_name, **exception_metadata(e))
        session.close
      end
      @health_timer.execute
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
      safe_log(:error, "consumer.health_check_file_error", path: file_path, **exception_metadata(e))
    end
  end
end
