# frozen_string_literal: true

require 'concurrent'
require 'json'
require 'securerandom'

module BugBunny
  # Clase de bajo nivel encargada de la publicación de mensajes en RabbitMQ.
  #
  # Actúa como el "motor" de envío del framework. Es responsable de:
  # 1. Serializar el payload del mensaje.
  # 2. Manejar la publicación asíncrona (Fire-and-Forget).
  # 3. Implementar el patrón RPC síncrono utilizando futuros (`Concurrent::IVar`).
  # 4. Gestionar la escucha de respuestas en la cola especial de RabbitMQ.
  class Producer
    include BugBunny::Observability

    # Bound de espera (segundos) que el publish thread aplica tras un ack positivo para
    # tolerar el scheduling race entre reader thread (donde Bunny invoca `on_return`) y
    # publish thread (donde se devuelve `wait_for_confirms`). AMQP garantiza que el
    # `basic.return` precede al `basic.ack` en la wire, así que en la práctica el event
    # ya está seteado al llegar acá; este wait es defensa contra GVL.
    RETURN_RACE_WINDOW_S = 0.05

    # Inicializa el productor.
    #
    # Prepara las estructuras de concurrencia necesarias para manejar múltiples
    # peticiones RPC simultáneas sobre la misma conexión.
    #
    # @param session [BugBunny::Session] Sesión activa de Bunny (wrapper).
    def initialize(session)
      @session = session
      @logger = BugBunny.configuration.logger
      # Mapa thread-safe para correlacionar IDs de petición con sus futuros (IVars)
      @pending_requests = Concurrent::Map.new
      @reply_listener_mutex = Mutex.new
      @reply_listener_started = false
    end

    # Envía un mensaje de forma asíncrona (Fire-and-Forget).
    #
    # Serializa el cuerpo del request, resuelve el exchange aplicando la cascada de
    # configuración y publica el mensaje sin esperar respuesta.
    #
    # @param request [BugBunny::Request] Objeto con la configuración del envío (body, exchange_options, etc).
    # @return [Hash] Un hash de éxito simbólico ({ 'status' => 202 }).
    def fire(request)
      publish_message(request)
      # Devolvemos un hash para evitar NoMethodError en el cliente (que espera una respuesta tipo Hash)
      { 'status' => 202, 'body' => nil }
    end

    # Envía un mensaje con Publisher Confirms síncronos (Fire-and-Forget confirmado).
    #
    # Publica el mensaje y bloquea el hilo actual hasta que el broker confirme su recepción
    # vía `wait_for_confirms`. Soporta `mandatory: true` con callback `on_return` para
    # mensajes que no pudieron rutearse.
    #
    # A diferencia de {#rpc} (que espera la respuesta de un Consumer remoto), aquí solo se
    # espera el ACK del propio broker — no hay round-trip al servicio destino.
    #
    # @param request [BugBunny::Request] Request con `mandatory`, `confirm_timeout`, `nack_raise`
    #   y/o `on_return` opcionales.
    # @return [Hash] `{ 'status' => 202, 'body' => nil }` si el broker confirmó la recepción.
    # @raise [BugBunny::RequestTimeout] Si el broker no confirma dentro de `confirm_timeout` segundos.
    # @raise [BugBunny::PublishNacked] Si el broker NACKea la publicación y `nack_raise` está activo
    #   (default `true` — ver {BugBunny::Configuration#nack_raise}).
    # @raise [BugBunny::PublishUnroutable] Si `mandatory: true` y el broker retorna el mensaje como
    #   no-ruteable, con `return_raise` activo (default `true` — ver
    #   {BugBunny::Configuration#return_raise}).
    # @raise [BugBunny::CommunicationError] Si el canal AMQP falla durante la publicación o confirm.
    def confirmed(request)
      return_listener = nil
      return_listener = setup_return_listener(request)
      started_at = monotonic_now
      publish_duration = publish_message(request)

      confirm_started_at = monotonic_now
      acked = wait_for_confirms!(request)
      confirm_duration = duration_s(confirm_started_at)

      handle_confirm_result(request, acked)
      handle_return_result(request, return_listener)
      log_confirmed(request, publish_duration, confirm_duration, started_at)

      { 'status' => 202, 'body' => nil }
    rescue BugBunny::Error
      raise
    rescue Bunny::Exception => e
      raise BugBunny::CommunicationError, "Publisher confirms failed: #{e.class}: #{e.message}"
    ensure
      teardown_return_listener(request, return_listener)
    end

    # Envía un mensaje y bloquea el hilo actual esperando una respuesta (RPC).
    #
    # Implementa el mecanismo "Direct Reply-to" de RabbitMQ (`amq.rabbitmq.reply-to`).
    #
    # @param request [BugBunny::Request] Objeto request configurado.
    # @return [Hash] El cuerpo de la respuesta parseado desde JSON.
    # @raise [BugBunny::RequestTimeout] Si el servidor no responde dentro del tiempo límite.
    # @raise [BugBunny::InternalServerError] Si la respuesta no es un JSON válido.
    def rpc(request)
      ensure_reply_listener!

      request.correlation_id ||= SecureRandom.uuid
      request.reply_to = 'amq.rabbitmq.reply-to'
      wait_timeout = request.timeout || BugBunny.configuration.rpc_timeout
      cid = request.correlation_id.to_s

      # Creamos un futuro (IVar) que actuará como semáforo
      future = Concurrent::IVar.new
      @pending_requests[cid] = future

      started_at = monotonic_now
      begin
        fire(request)

        safe_log(:debug, 'producer.rpc_waiting', messaging_message_id: cid, timeout_s: wait_timeout)

        # Bloqueamos el hilo aquí hasta que llegue la respuesta o expire el timeout
        result = future.value(wait_timeout)

        raise BugBunny::RequestTimeout, "Timeout waiting for RPC: #{request.path} [#{request.method}]" if result.nil?

        BugBunny.configuration.on_rpc_reply&.call(result[:headers])
        log_rpc_response_received(request, cid, result, started_at)

        parse_response(result[:body])
      ensure
        # Limpieza vital para evitar fugas de memoria en el mapa
        @pending_requests.delete(cid)
      end
    end

    private

    # Resuelve exchange, serializa payload, logea y publica el mensaje.
    # Compartido por {#fire} y {#confirmed}.
    #
    # Emite `producer.publish` antes y `producer.published` después con `duration_s`
    # midiendo solo el `basic_publish` (TCP enqueue al broker, sin esperar ACK).
    #
    # @param request [BugBunny::Request]
    # @return [Float] duración del publish en segundos.
    def publish_message(request)
      x = @session.exchange(
        name: request.exchange,
        type: request.exchange_type,
        opts: request.exchange_options
      )
      payload = serialize_message(request.body)
      log_request(request, payload)

      started_at = monotonic_now
      x.publish(payload, request.amqp_options.merge(routing_key: request.final_routing_key))
      publish_duration = duration_s(started_at)

      log_published(request, publish_duration)
      publish_duration
    end

    # @api private
    def log_published(request, publish_duration_s)
      safe_log(:info, 'producer.published',
               method: request.method.to_s.upcase, path: request.path,
               routing_key: request.final_routing_key,
               messaging_message_id: request.correlation_id,
               duration_s: publish_duration_s)
    end

    # @api private
    def log_rpc_response_received(request, cid, result, started_at)
      safe_log(:info, 'producer.rpc_response_received',
               method: request.method.to_s.upcase, path: request.path,
               messaging_system: 'rabbitmq', messaging_operation: 'receive', messaging_message_id: cid,
               duration_s: duration_s(started_at),
               response_body: result[:body]&.truncate(500),
               response_headers: result[:headers]&.to_json&.truncate(300))
    end

    # @api private
    def log_confirmed(request, publish_duration_s, confirm_duration_s, started_at)
      safe_log(:info, 'producer.confirmed',
               method: request.method.to_s.upcase, path: request.path,
               routing_key: request.final_routing_key,
               messaging_message_id: request.correlation_id,
               publish_duration_s: publish_duration_s,
               confirm_duration_s: confirm_duration_s,
               duration_s: duration_s(started_at))
    end

    # Espera la confirmación del broker con timeout opcional.
    # Bunny 2.24 no soporta timeout nativo en `wait_for_confirms`, así que delegamos
    # la espera a un hilo auxiliar y usamos `Concurrent::IVar#value(timeout)` como reloj.
    #
    # @param request [BugBunny::Request]
    # @raise [BugBunny::RequestTimeout] Si el broker no confirma a tiempo.
    # @return [Boolean] true si todas las confirmaciones fueron positivas.
    def wait_for_confirms!(request)
      timeout = request.confirm_timeout
      return @session.channel.wait_for_confirms if timeout.nil?

      ivar = Concurrent::IVar.new
      Thread.new do
        ivar.set(@session.channel.wait_for_confirms)
      rescue StandardError => e
        ivar.fail(e)
      end

      result = ivar.value(timeout)
      return result if ivar.complete?

      raise BugBunny::RequestTimeout,
            "Timeout (#{timeout}s) waiting for publisher confirms: #{request.path}"
    end

    # Procesa el resultado de `wait_for_confirms`.
    #
    # Si el broker NACKeó (`acked == false`), logea el evento `producer.confirms_nacked`
    # y opcionalmente levanta {BugBunny::PublishNacked} según el flag `nack_raise`
    # resuelto desde el request o la configuración global.
    #
    # @param request [BugBunny::Request]
    # @param acked [Boolean] Resultado de `wait_for_confirms` (true = todos los confirms positivos).
    # @raise [BugBunny::PublishNacked] Si hay NACK y `nack_raise?` es true.
    # @return [void]
    def handle_confirm_result(request, acked)
      return if acked

      count = nacked_count
      safe_log(:warn, 'producer.confirms_nacked', count: count, path: request.path)
      return unless nack_raise?(request)

      raise BugBunny::PublishNacked.new(path: request.path, nacked_count: count)
    end

    # Cuenta los delivery tags NACKeados reportados por el canal.
    #
    # @return [Integer]
    def nacked_count
      ch = @session.channel
      return 0 unless ch.respond_to?(:nacked_set)

      ch.nacked_set&.size || 0
    end

    # Resuelve el flag `nack_raise` con prioridad request > configuración global.
    #
    # @param request [BugBunny::Request]
    # @return [Boolean]
    def nack_raise?(request)
      return request.nack_raise unless request.nack_raise.nil?

      BugBunny.configuration.nack_raise
    end

    # Resuelve el flag `return_raise` con prioridad request > configuración global.
    # El flag solo tiene efecto cuando `mandatory: true` — sin mandatory el broker
    # nunca emite `basic.return`.
    #
    # @param request [BugBunny::Request]
    # @return [Boolean]
    def return_raise?(request)
      return false unless request.mandatory

      return request.return_raise unless request.return_raise.nil?

      BugBunny.configuration.return_raise
    end

    # Registra un listener de `basic.return` en la Session asociada al `correlation_id`
    # del request. Si return_raise? es false (mandatory off o flag desactivado), retorna
    # `nil` y el resto del flow ignora la lógica de unroutable.
    #
    # Auto-asigna `correlation_id` si falta — sin cid no hay clave de correlación.
    #
    # @param request [BugBunny::Request]
    # @return [Hash, nil] Hash con `:cid` y `:slot` (el slot expone `:event` y `:info`),
    #   o `nil` si no aplica.
    def setup_return_listener(request)
      return nil unless return_raise?(request)

      request.correlation_id ||= SecureRandom.uuid
      cid = request.correlation_id.to_s
      _event, slot = @session.register_return_listener(cid)
      { cid: cid, slot: slot }
    end

    # Tras un ack positivo, espera brevemente al event del listener para tolerar el
    # scheduling race entre reader thread (donde corre `on_return`) y publish thread.
    # En AMQP el `basic.return` precede al `basic.ack`, así que normalmente el event
    # ya está seteado al llegar acá; el bounded wait defiende contra GVL/scheduling.
    #
    # @param request [BugBunny::Request]
    # @param return_listener [Hash, nil] Resultado de {#setup_return_listener}.
    # @return [void]
    # @raise [BugBunny::PublishUnroutable] Si el listener recibió un return.
    def handle_return_result(request, return_listener)
      return unless return_listener

      slot = return_listener[:slot]
      slot[:event].wait(RETURN_RACE_WINDOW_S)
      info = slot[:info]
      return if info.nil?

      raise_unroutable!(request, return_listener[:cid], info)
    end

    # Logea y levanta {BugBunny::PublishUnroutable} con los datos del return.
    #
    # @param request [BugBunny::Request]
    # @param cid [String]
    # @param info [Bunny::ReturnInfo, #exchange, #routing_key, #reply_code, #reply_text]
    # @raise [BugBunny::PublishUnroutable]
    def raise_unroutable!(request, cid, info)
      safe_log(:warn, 'producer.publish_unroutable',
               path: request.path,
               exchange: info.exchange,
               routing_key: info.routing_key,
               reply_code: info.reply_code,
               reply_text: info.reply_text,
               messaging_message_id: cid)

      raise BugBunny::PublishUnroutable.new(
        path: request.path,
        exchange: info.exchange,
        routing_key: info.routing_key,
        reply_code: info.reply_code,
        reply_text: info.reply_text,
        correlation_id: cid
      )
    end

    # Cleanup del listener en la Session. Siempre se llama desde el `ensure` de
    # {#confirmed}, sea cual sea el outcome (ack, nack, timeout, return).
    #
    # @param request [BugBunny::Request]
    # @param return_listener [Hash, nil]
    # @return [void]
    def teardown_return_listener(_request, return_listener)
      return unless return_listener

      @session.unregister_return_listener(return_listener[:cid])
    end

    # Registra la petición en el log calculando las opciones de infraestructura.
    #
    # @param request [BugBunny::Request] Objeto Request que se está enviando.
    # @param payload [String] El cuerpo del mensaje serializado.
    def log_request(request, payload)
      verb = request.method.to_s.upcase
      target = request.path
      rk = request.final_routing_key
      id = request.correlation_id

      otel_fields = BugBunny::OTel.messaging_headers(
        operation: 'publish',
        destination: request.exchange,
        routing_key: rk,
        message_id: id
      )

      # 📊 LOGGING DE OBSERVABILIDAD: Calculamos las opciones finales para mostrarlas en consola
      final_x_opts = BugBunny::Session::DEFAULT_EXCHANGE_OPTIONS
                     .merge(BugBunny.configuration.exchange_options || {})
                     .merge(request.exchange_options || {})

      safe_log(:info, 'producer.publish', method: verb, path: target, **otel_fields)
      safe_log(:debug, 'producer.publish_detail', messaging_destination_name: request.exchange,
                                                  exchange_opts: final_x_opts)
      return unless payload.is_a?(String)

      safe_log(:info, 'producer.publish_payload',
               payload: payload.truncate(500),
               payload_class: payload.class.name,
               body_size: request.body.nil? ? 0 : request.body.size)
    end

    # Serializa el mensaje para su transporte.
    #
    # @param msg [Hash, String, Object] El mensaje a serializar.
    # @return [String] Cadena JSON o string crudo.
    def serialize_message(msg)
      msg.is_a?(Hash) ? msg.to_json : msg.to_s
    end

    # Intenta parsear la respuesta recibida.
    #
    # @param payload [String] El cuerpo de la respuesta recibida.
    # @return [Hash] El JSON parseado.
    # @raise [BugBunny::InternalServerError] Si el payload no es JSON válido.
    def parse_response(payload)
      JSON.parse(payload)
    rescue JSON::ParserError
      raise BugBunny::InternalServerError, 'Invalid JSON response'
    end

    # Inicia el consumidor de respuestas RPC de forma perezosa (Lazy Initialization).
    #
    # Utiliza un patrón de "Double-Checked Locking" con Mutex para asegurar que
    # solo se crea un listener por instancia de Producer.
    #
    # @return [void]
    def ensure_reply_listener!
      return if @reply_listener_started

      @reply_listener_mutex.synchronize do
        return if @reply_listener_started

        safe_log(:debug, 'producer.reply_listener_start')

        # Consumimos sin ack (auto-ack) porque reply-to no soporta acks manuales de forma estándar
        @session.channel.basic_consume('amq.rabbitmq.reply-to', '', true, false, nil) do |_, props, body|
          cid = props.correlation_id.to_s
          if (future = @pending_requests[cid])
            future.set({ body: body, headers: props.headers || {} })
          else
            safe_log(:warn, 'producer.rpc_response_orphaned', correlation_id: cid)
          end
        end
        @reply_listener_started = true
      end
    end
  end
end
