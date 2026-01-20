require 'concurrent'
require 'json'
require 'securerandom'

module BugBunny
  # Clase de bajo nivel que maneja la publicación de mensajes y la espera de respuestas RPC.
  class Producer
    # @param session [BugBunny::Session] Sesión activa.
    def initialize(session)
      @session = session
      @pending_requests = Concurrent::Map.new
      @reply_listener_mutex = Mutex.new
      @reply_listener_started = false
    end

    # Envía un mensaje sin esperar respuesta (Fire-and-Forget).
    # @param request [BugBunny::Request] Objeto request.
    def fire(request)
      x = @session.exchange(name: request.exchange, type: request.exchange_type)
      payload = serialize_message(request.body)
      opts = request.amqp_options

      BugBunny.configuration.logger.info("[BugBunny] Publishing to #{request.exchange}/#{request.final_routing_key}")

      x.publish(payload, opts.merge(routing_key: request.final_routing_key))
    end

    # Envía un mensaje y bloquea esperando la respuesta RPC.
    # Usa 'amq.rabbitmq.reply-to' para evitar crear colas temporales por request.
    #
    # @param request [BugBunny::Request] Objeto request.
    # @return [Hash] Respuesta parseada.
    # @raise [BugBunny::RequestTimeout] Timeout.
    def rpc(request)
      ensure_reply_listener!

      request.correlation_id ||= SecureRandom.uuid
      request.reply_to = 'amq.rabbitmq.reply-to'
      wait_timeout = request.timeout || BugBunny.configuration.rpc_timeout

      future = Concurrent::IVar.new
      @pending_requests[request.correlation_id] = future

      begin
        fire(request)
        response_payload = future.value(wait_timeout)

        if response_payload.nil?
          raise BugBunny::RequestTimeout, "Timeout waiting for RPC: #{request.action}"
        end

        parse_response(response_payload)
      ensure
        @pending_requests.delete(request.correlation_id)
      end
    end

    private

    def serialize_message(msg)
      msg.is_a?(Hash) ? msg.to_json : msg.to_s
    end

    def parse_response(payload)
      JSON.parse(payload)
    rescue JSON::ParserError
      raise BugBunny::InternalServerError, "Invalid JSON response"
    end

    def ensure_reply_listener!
      return if @reply_listener_started

      @reply_listener_mutex.synchronize do
        return if @reply_listener_started

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
