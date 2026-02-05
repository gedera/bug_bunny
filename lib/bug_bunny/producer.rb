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
    # Serializa el cuerpo del request, resuelve el exchange y publica el mensaje
    # sin esperar confirmación ni respuesta del consumidor.
    #
    # @param request [BugBunny::Request] Objeto con la configuración del envío (body, routing_key, etc).
    # @return [void]
    def fire(request)
      x = @session.exchange(name: request.exchange, type: request.exchange_type)
      payload = serialize_message(request.body)
      opts = request.amqp_options

      BugBunny.configuration.logger.info("[BugBunny] Publishing to #{request.exchange}/#{request.final_routing_key}")

      x.publish(payload, opts.merge(routing_key: request.final_routing_key))
    end

    # Envía un mensaje y bloquea el hilo actual esperando una respuesta (RPC).
    #
    # Implementa el mecanismo "Direct Reply-to" de RabbitMQ (`amq.rabbitmq.reply-to`)
    # para recibir la respuesta directamente sin necesidad de crear colas temporales
    # por cada petición, lo cual mejora significativamente el rendimiento.
    #
    # El flujo es:
    # 1. Asegura que hay un consumidor escuchando en `amq.rabbitmq.reply-to`.
    # 2. Genera un `correlation_id` único.
    # 3. Crea una promesa (`Concurrent::IVar`) y la registra.
    # 4. Publica el mensaje y bloquea esperando que la promesa se resuelva.
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

      # Creamos un futuro (IVar) que actuará como semáforo
      future = Concurrent::IVar.new
      @pending_requests[request.correlation_id] = future

      begin
        fire(request)

        # Bloqueamos el hilo aquí hasta que llegue la respuesta o expire el timeout
        response_payload = future.value(wait_timeout)

        if response_payload.nil?
          raise BugBunny::RequestTimeout, "Timeout waiting for RPC: #{request.action}"
        end

        parse_response(response_payload)
      ensure
        # Limpieza vital para evitar fugas de memoria en el mapa
        @pending_requests.delete(request.correlation_id)
      end
    end

    private

    # Serializa el mensaje para su transporte.
    # @param msg [Hash, String, Object] El mensaje a serializar.
    # @return [String] Cadena JSON o string crudo.
    def serialize_message(msg)
      msg.is_a?(Hash) ? msg.to_json : msg.to_s
    end

    # Intenta parsear la respuesta recibida.
    # @raise [BugBunny::InternalServerError] Si el payload no es JSON válido.
    def parse_response(payload)
      JSON.parse(payload)
    rescue JSON::ParserError
      raise BugBunny::InternalServerError, "Invalid JSON response"
    end

    # Inicia el consumidor de respuestas RPC de forma perezosa (Lazy Initialization).
    #
    # Utiliza un patrón de "Double-Checked Locking" con Mutex para asegurar que
    # solo se crea un listener por instancia de Producer, incluso en entornos multi-hilo.
    #
    # Escucha en la pseudo-cola `amq.rabbitmq.reply-to`. Cuando llega un mensaje,
    # busca el `correlation_id` en el mapa de pendientes y completa el futuro (`IVar`),
    # desbloqueando así al hilo que llamó a {#rpc}.
    def ensure_reply_listener!
      return if @reply_listener_started

      @reply_listener_mutex.synchronize do
        return if @reply_listener_started

        # Consumimos sin ack (auto-ack) porque reply-to no soporta acks manuales de forma estándar
        @session.channel.basic_consume('amq.rabbitmq.reply-to', '', true, false, nil) do |_, props, body|
          if (future = @pending_requests[props.correlation_id])
            future.set(body)
          end
        end
        @reply_listener_started = true
      end
    end
  end
end
