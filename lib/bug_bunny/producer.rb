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
    # Inicializa el productor.
    #
    # Prepara las estructuras de concurrencia necesarias para manejar múltiples
    # peticiones RPC simultáneas sobre la misma conexión.
    #
    # @param session [BugBunny::Session] Sesión activa de Bunny (wrapper).
    def initialize(session)
      @session = session
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
    # @return [void]
    def fire(request)
      # Obtenemos el exchange pasando las opciones específicas del request para la fusión en cascada
      x = @session.exchange(
        name: request.exchange,
        type: request.exchange_type,
        opts: request.exchange_options
      )

      payload = serialize_message(request.body)
      opts = request.amqp_options

      log_request(request, payload)

      x.publish(payload, opts.merge(routing_key: request.final_routing_key))
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

      begin
        fire(request)

        BugBunny.configuration.logger.debug { "component=bug_bunny event=rpc_waiting correlation_id=#{cid} timeout_s=#{wait_timeout}" }

        # Bloqueamos el hilo aquí hasta que llegue la respuesta o expire el timeout
        response_payload = future.value(wait_timeout)

        if response_payload.nil?
          raise BugBunny::RequestTimeout, "Timeout waiting for RPC: #{request.path} [#{request.method}]"
        end

        parse_response(response_payload)
      ensure
        # Limpieza vital para evitar fugas de memoria en el mapa
        @pending_requests.delete(cid)
      end
    end

    private

    # Registra la petición en el log calculando las opciones de infraestructura.
    #
    # @param request [BugBunny::Request] Objeto Request que se está enviando.
    # @param payload [String] El cuerpo del mensaje serializado.
    def log_request(request, payload)
      verb = request.method.to_s.upcase
      target = request.path
      rk = request.final_routing_key
      id = request.correlation_id

      # 📊 LOGGING DE OBSERVABILIDAD: Calculamos las opciones finales para mostrarlas en consola
      final_x_opts = BugBunny::Session::DEFAULT_EXCHANGE_OPTIONS
                       .merge(BugBunny.configuration.exchange_options || {})
                       .merge(request.exchange_options || {})

      BugBunny.configuration.logger.info("component=bug_bunny event=publish method=#{verb} path=#{target} routing_key=#{rk} correlation_id=#{id}")
      BugBunny.configuration.logger.debug { "component=bug_bunny event=publish_detail exchange=#{request.exchange} exchange_opts=#{final_x_opts}" }
      BugBunny.configuration.logger.debug { "component=bug_bunny event=publish_payload payload=#{payload.truncate(300).inspect}" } if payload.is_a?(String)
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
      raise BugBunny::InternalServerError, "Invalid JSON response"
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

        BugBunny.configuration.logger.debug { 'component=bug_bunny event=reply_listener_start queue=amq.rabbitmq.reply-to' }

        # Consumimos sin ack (auto-ack) porque reply-to no soporta acks manuales de forma estándar
        @session.channel.basic_consume('amq.rabbitmq.reply-to', '', true, false, nil) do |_, props, body|
          cid = props.correlation_id.to_s
          BugBunny.configuration.logger.debug { "component=bug_bunny event=rpc_response_received correlation_id=#{cid}" }
          if (future = @pending_requests[cid])
            future.set(body)
          else
            BugBunny.configuration.logger.warn("component=bug_bunny event=rpc_response_orphaned correlation_id=#{cid}")
          end
        end
        @reply_listener_started = true
      end
    end
  end
end
