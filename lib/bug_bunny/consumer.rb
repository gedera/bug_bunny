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

    # Método de conveniencia para instanciar y drenar en un solo paso.
    #
    # @param connection [Bunny::Session] Una conexión TCP activa a RabbitMQ.
    # @param args [Hash] Argumentos que se pasarán al método {#drain}.
    # @return [Integer] Cantidad de mensajes procesados.
    def self.drain(connection:, **args)
      new(connection).drain(**args)
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
    def subscribe(queue_name:, exchange_name:, routing_key:, exchange_type: 'direct', exchange_opts: {},
                  queue_opts: {}, block: true)
      attempt = 0

      begin
        queue = declare_infrastructure(queue_name: queue_name, exchange_name: exchange_name,
                                       routing_key: routing_key, exchange_type: exchange_type,
                                       exchange_opts: exchange_opts, queue_opts: queue_opts)

        start_health_check(queue_name)

        queue.subscribe(manual_ack: true, block: block) do |delivery_info, properties, body|
          handle_delivery(delivery_info, properties, body)
        end
      rescue StandardError => e
        attempt += 1
        max_attempts = BugBunny.configuration.max_reconnect_attempts

        if max_attempts && attempt >= max_attempts
          safe_log(:error, 'consumer.reconnect_exhausted', max_attempts_count: max_attempts, **exception_metadata(e))
          raise
        end

        wait = [
          BugBunny.configuration.network_recovery_interval * (2**(attempt - 1)),
          BugBunny.configuration.max_reconnect_interval
        ].min

        safe_log(:error, 'consumer.connection_error', attempt_count: attempt,
                                                      max_attempts_count: max_attempts || 'infinity', retry_in_s: wait, **exception_metadata(e))
        sleep wait
        retry
      end
    ensure
      shutdown
    end

    # Consume la cola hasta vaciarla y retorna: el modo para correr un consumidor como job
    # (Sidekiq, un Job de k8s) en vez de como un proceso eterno.
    #
    # A diferencia de `subscribe(block: false)`, que retorna al instante, este método
    # bloquea mientras haya mensajes y vuelve cuando la cola queda quieta:
    #
    # 1. Si la cola tiene 0 mensajes al arrancar, retorna `0` sin esperar.
    # 2. Si hay mensajes, se suscribe con `manual_ack: true` respetando `channel_prefetch`,
    #    igual que el modo bloqueante.
    # 3. Termina cuando pasaron `drain_idle_timeout` segundos (ver {Configuration}) sin
    #    entregas y no queda ningún mensaje en proceso. Cancela el consumer y cierra el
    #    canal ({#shutdown}).
    #
    # **Mensajes que llegan mientras drena:** un mensaje que llega antes de que venza la
    # ventana de inactividad se procesa en esta vuelta; lo que llega después queda para
    # la próxima corrida. Un mensaje entregado en el instante del cancel puede no llegar a
    # ack-earse: vuelve a la cola (at-least-once, nunca se pierde).
    #
    # No arranca el health check ni reintenta la conexión: un job que falla lo reintenta
    # el framework que lo corre.
    #
    # @param queue_name [String] Nombre de la cola a drenar.
    # @param exchange_name [String] Nombre del exchange al cual enlazar la cola.
    # @param routing_key [String] Patrón de enrutamiento (ej: 'users.*').
    # @param exchange_type [String] Tipo de exchange ('direct', 'topic', 'fanout').
    # @param exchange_opts [Hash] Opciones adicionales para el exchange (durable, auto_delete).
    # @param queue_opts [Hash] Opciones adicionales para la cola (durable, auto_delete).
    # @return [Integer] Cantidad de mensajes procesados en esta vuelta (incluye los rechazados:
    #   también salieron de la cola).
    def drain(queue_name:, exchange_name:, routing_key:, exchange_type: 'direct', exchange_opts: {},
              queue_opts: {})
      started_at = monotonic_now
      queue = declare_infrastructure(queue_name: queue_name, exchange_name: exchange_name,
                                     routing_key: routing_key, exchange_type: exchange_type,
                                     exchange_opts: exchange_opts, queue_opts: queue_opts)

      pending_count = queue.message_count
      safe_log(:info, 'consumer.drain_start', queue: queue_name, pending_count: pending_count)
      return 0 if pending_count.zero?

      processed_count = consume_until_idle(queue)

      safe_log(:info, 'consumer.drain_finished', queue: queue_name, processed_count: processed_count,
                                                 duration_s: (monotonic_now - started_at).round(3))
      processed_count
    ensure
      shutdown
    end

    # Detiene el health check timer y cierra el canal de forma ordenada.
    #
    # Llamar explícitamente al hacer shutdown del worker (SIGTERM, at_exit, etc.).
    # También se invoca automáticamente cuando `subscribe` termina por cualquier motivo.
    #
    # @return [void]
    def shutdown
      safe_log(:info, 'consumer.shutdown')
      @health_timer&.shutdown
      @health_timer = nil
      session.close
    end

    private

    # Declara exchange y cola, los enlaza y loguea las opciones efectivas.
    #
    # @return [Bunny::Queue] La cola declarada y enlazada.
    def declare_infrastructure(queue_name:, exchange_name:, routing_key:, exchange_type:, exchange_opts:, queue_opts:)
      exchange = session.exchange(name: exchange_name, type: exchange_type, opts: exchange_opts)
      queue = session.queue(queue_name, queue_opts)
      queue.bind(exchange, routing_key: routing_key)

      # 📊 LOGGING DE OBSERVABILIDAD: Calculamos las opciones finales para mostrarlas en consola
      effective_exchange_opts = BugBunny::Session::DEFAULT_EXCHANGE_OPTIONS
                                .merge(BugBunny.configuration.exchange_options || {})
                                .merge(exchange_opts || {})
      effective_queue_opts = BugBunny::Session::DEFAULT_QUEUE_OPTIONS
                             .merge(BugBunny.configuration.queue_options || {})
                             .merge(queue_opts || {})

      safe_log(:info, 'consumer.start', queue: queue_name, queue_opts: effective_queue_opts)
      safe_log(:info, 'consumer.bound', exchange: exchange_name, exchange_type: exchange_type,
                                        routing_key: routing_key, exchange_opts: effective_exchange_opts)
      queue
    end

    # Pasa una entrega por los middlewares y el logger con tags, y la procesa.
    #
    # @return [void]
    def handle_delivery(delivery_info, properties, body)
      trace_id = properties.correlation_id
      logger = BugBunny.configuration.logger

      core = lambda {
        if logger.respond_to?(:tagged)
          logger.tagged(trace_id) { process_message(delivery_info, properties, body) }
        elsif defined?(Rails) && Rails.logger.respond_to?(:tagged)
          Rails.logger.tagged(trace_id) { process_message(delivery_info, properties, body) }
        else
          process_message(delivery_info, properties, body)
        end
      }

      BugBunny.configuration.consumer_middlewares.call(delivery_info, properties, body, &core)
    end

    # Se suscribe sin bloquear y espera a que la cola quede quieta `drain_idle_timeout`
    # segundos sin ningún mensaje en proceso; después cancela la suscripción.
    #
    # @return [Integer] Cantidad de mensajes procesados.
    def consume_until_idle(queue)
      idle_timeout = BugBunny.configuration.drain_idle_timeout
      poll_interval = BugBunny.configuration.drain_poll_interval
      tracker = BugBunny::DrainTracker.new

      subscription = queue.subscribe(manual_ack: true, block: false) do |delivery_info, properties, body|
        tracker.track { handle_delivery(delivery_info, properties, body) }
      end

      sleep poll_interval until tracker.idle?(idle_timeout)

      subscription.cancel
      sleep poll_interval while tracker.busy?
      tracker.processed
    end

    # @return [Float] Reloj monotónico en segundos.
    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

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

      # Campos OTel semantic conventions para los log events del consumer.
      # Se mergean con ** en los safe_log de recepción y procesamiento.
      otel_fields = BugBunny::OTel.messaging_headers(
        operation: 'process',
        destination: delivery_info.exchange,
        routing_key: delivery_info.routing_key,
        message_id: properties.correlation_id
      )

      # 1. Validación de Headers (URL path)
      path = properties.type || (properties.headers && properties.headers['path'])

      if path.nil? || path.empty?
        safe_log(:error, 'consumer.message_rejected', reason: :missing_type_header)
        session.channel.reject(delivery_info.delivery_tag, false)
        return
      end

      # 2. Recuperación Robusta del Verbo HTTP
      headers_hash = properties.headers || {}
      http_method = (headers_hash['x-http-method'] || headers_hash['method'] || 'GET').to_s.upcase

      safe_log(:info, 'consumer.message_received', method: http_method, path: path,
                                                   routing_key: delivery_info.routing_key, **otel_fields)
      safe_log(:info, 'consumer.message_received_body', body: body&.truncate(500), body_size: body&.size || 0)

      # ===================================================================
      # 3. Ruteo Declarativo
      # ===================================================================
      normalized_path = path.gsub(%r{^/|/$}, '')

      uri = URI.parse("http://dummy/#{normalized_path}")
      clean_path = uri.path.delete_prefix('/dummy/').delete_prefix('/')

      # Extraemos query params (ej. /nodes?status=active)
      query_params = uri.query ? Rack::Utils.parse_nested_query(uri.query) : {}
      query_params = query_params.with_indifferent_access if defined?(ActiveSupport::HashWithIndifferentAccess)

      # Le preguntamos al motor de rutas global quién debe manejar esto
      route_info = BugBunny.routes.recognize(http_method, clean_path)

      if route_info.nil?
        safe_log(:warn, 'consumer.route_not_found', method: http_method, path: clean_path)
        handle_routing_error(properties, "No route matches [#{http_method}] \"#{clean_path}\"")
        session.channel.reject(delivery_info.delivery_tag, false)
        return
      end

      # Fusionamos los parámetros extraídos de la URL (ej. :id) con los query_params
      final_params = query_params.merge(route_info[:params])

      # ===================================================================
      # 4. Instanciación del Controlador
      # ===================================================================
      base_namespace = route_info[:namespace] || BugBunny.configuration.controller_namespace
      controller_name = route_info[:controller].camelize
      controller_class_name = "#{base_namespace}::#{controller_name}Controller"

      begin
        controller_class = controller_class_name.constantize
      rescue NameError
        safe_log(:warn, 'consumer.controller_not_found', controller: controller_class_name)
        handle_routing_error(properties, "Controller #{controller_class_name} not found")
        session.channel.reject(delivery_info.delivery_tag, false)
        return
      end

      # Verificación estricta de Seguridad (RCE Prevention)
      unless controller_class < BugBunny::Controller
        safe_log(:error, 'consumer.security_violation', reason: :invalid_controller, controller: controller_class)
        handle_fatal_error(properties, 403, 'Forbidden', 'Invalid Controller Class')
        session.channel.reject(delivery_info.delivery_tag, false)
        return
      end

      safe_log(:debug, 'consumer.route_matched', controller: controller_class_name, action: route_info[:action])

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

      reply(response_payload, properties.reply_to, properties.correlation_id) if properties.reply_to

      session.channel.ack(delivery_info.delivery_tag)

      safe_log(:info, 'consumer.message_processed',
               response_status: response_payload[:status],
               duration_s: duration_s(start_time),
               controller: controller_class_name,
               action: route_info[:action],
               **otel_fields)
    rescue StandardError => e
      safe_log(:error, 'consumer.execution_error', duration_s: duration_s(start_time), **exception_metadata(e))
      safe_log(:debug, 'consumer.execution_error_backtrace', backtrace: e.backtrace.first(5).join(' | '))
      handle_fatal_error(properties, 500, 'Internal Server Error', e.message, e)
      session.channel.reject(delivery_info.delivery_tag, false)
    end

    # Envía una respuesta al cliente RPC utilizando Direct Reply-to.
    #
    # @param payload [Hash] Cuerpo de la respuesta ({ status: ..., body: ... }).
    # @param reply_to [String] Cola de respuesta (generalmente pseudo-cola amq.rabbitmq.reply-to).
    # @param correlation_id [String] ID para correlacionar la respuesta con la petición original.
    # @return [void]
    def reply(payload, reply_to, correlation_id)
      safe_log(:info, 'consumer.rpc_reply',
               reply_to: reply_to,
               messaging_message_id: correlation_id,
               response_status: payload[:status],
               response_body: payload[:body]&.to_json&.truncate(500),
               response_body_size: payload[:body]&.to_json&.size || 0)
      otel_headers = BugBunny::OTel.messaging_headers(
        operation: 'publish',
        destination: '',
        routing_key: reply_to,
        message_id: correlation_id
      )
      extra_headers = BugBunny.configuration.rpc_reply_headers&.call || {}
      session.channel.default_exchange.publish(
        payload.to_json,
        routing_key: reply_to,
        correlation_id: correlation_id,
        content_type: 'application/json',
        headers: otel_headers.transform_keys(&:to_s).merge(extra_headers)
      )
    end

    # Maneja errores fatales asegurando que el cliente reciba una respuesta.
    # Evita que el cliente RPC se quede esperando hasta el timeout.
    #
    # @param properties [Bunny::MessageProperties] Headers y propiedades AMQP.
    # @param status [Integer] Código de estado HTTP.
    # @param error_title [String] Título del error.
    # @param detail [String] Detalle del error.
    # @param exception [StandardError, nil] Excepción original (para status 500).
    # @api private
    # Maneja errores de enrutamiento (ruta o controller no encontrado).
    #
    # Envía una respuesta 404 con `error_type: 'routing_error'` para que el
    # middleware del productor pueda levantar {BugBunny::RoutingError} en vez
    # de un {BugBunny::NotFound} genérico.
    #
    # @param properties [Bunny::MessageProperties] Headers y propiedades AMQP.
    # @param detail [String] Descripción del error de routing.
    # @api private
    def handle_routing_error(properties, detail)
      return unless properties.reply_to

      body = { error: 'Not Found', detail: detail, error_type: 'routing_error' }
      reply({ status: 404, body: body }, properties.reply_to, properties.correlation_id)
    end

    def handle_fatal_error(properties, status, error_title, detail, exception = nil)
      return unless properties.reply_to

      body = { error: error_title, detail: detail }

      body[:bug_bunny_exception] = BugBunny::RemoteError.serialize(exception) if status == 500 && exception

      error_payload = { status: status, body: body }
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
        safe_log(:warn, 'consumer.health_check_failed', queue: q_name, **exception_metadata(e))
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
      safe_log(:error, 'consumer.health_check_file_error', path: file_path, **exception_metadata(e))
    end
  end
end
