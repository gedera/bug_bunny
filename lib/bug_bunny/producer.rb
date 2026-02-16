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
    # Serializa el cuerpo del request, resuelve el exchange y publica el mensaje
    # sin esperar confirmación ni respuesta del consumidor.
    #
    # @param request [BugBunny::Request] Objeto con la configuración del envío (body, routing_key, etc).
    # @return [void]
    def fire(request)
      x = @session.exchange(name: request.exchange, type: request.exchange_type)
      payload = serialize_message(request.body)

      log_request(request)

      x.publish(payload, request.amqp_options.merge(routing_key: request.final_routing_key))
    end

    # Envía un mensaje y bloquea el hilo actual esperando una respuesta (RPC).
    #
    # Implementa el mecanismo "Direct Reply-to" de RabbitMQ (`amq.rabbitmq.reply-to`)
    # para recibir la respuesta directamente sin necesidad de crear colas temporales.
    #
    # @param request [BugBunny::Request] Objeto request configurado.
    # @return [Hash] El cuerpo de la respuesta parseado desde JSON.
    # @raise [BugBunny::RequestTimeout] Si el servidor no responde dentro del tiempo límite.
    # @raise [BugBunny::InternalServerError] Si la respuesta no es un JSON válido.
    def rpc(request)
      ensure_reply_listener!
      prepare_rpc_request(request)

      future = Concurrent::IVar.new
      @pending_requests[request.correlation_id] = future

      begin
        fire(request)
        wait_for_response(future, request)
      ensure
        @pending_requests.delete(request.correlation_id)
      end
    end

    private

    def prepare_rpc_request(request)
      request.correlation_id ||= SecureRandom.uuid
      request.reply_to = 'amq.rabbitmq.reply-to'
    end

    def wait_for_response(future, request)
      timeout = request.timeout || BugBunny.configuration.rpc_timeout
      response_payload = future.value(timeout)

      if response_payload.nil?
        raise BugBunny::RequestTimeout, "Timeout waiting for RPC: #{request.path} [#{request.method}]"
      end

      parse_response(response_payload)
    end

    def log_request(req)
      verb = req.method.to_s.upcase
      ex_info = "'#{req.exchange}' (Type: #{req.exchange_type})"
      rk = req.final_routing_key

      BugBunny.configuration.logger.info(
        "[BugBunny] [#{verb}] '/#{req.path}' | Exchange: #{ex_info} | Routing Key: '#{rk}'"
      )
    end

    # Serializa el mensaje para su transporte.
    def serialize_message(msg)
      msg.is_a?(Hash) ? msg.to_json : msg.to_s
    end

    # Intenta parsear la respuesta recibida.
    def parse_response(payload)
      JSON.parse(payload)
    rescue JSON::ParserError
      raise BugBunny::InternalServerError, 'Invalid JSON response'
    end

    # Inicia el consumidor de respuestas RPC de forma perezosa (Lazy Initialization).
    #
    # Utiliza un patrón de "Double-Checked Locking" con Mutex para asegurar que
    # solo se crea un listener por instancia de Producer.
    def ensure_reply_listener!
      return if @reply_listener_started

      @reply_listener_mutex.synchronize do
        return if @reply_listener_started

        start_reply_consumer
        @reply_listener_started = true
      end
    end

    def start_reply_consumer
      # Consumimos sin ack (auto-ack) porque reply-to no soporta acks manuales de forma estándar
      @session.channel.basic_consume('amq.rabbitmq.reply-to', '', true, false, nil) do |_, props, body|
        if (future = @pending_requests[props.correlation_id])
          future.set(body)
        end
      end
    end
  end
end
