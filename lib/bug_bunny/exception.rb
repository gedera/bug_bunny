module BugBunny
  # Base de todas las excepciones de la gema
  class Error < ::StandardError; end

  # Errores de conexión (Bunny, Red, TCP)
  class CommunicationError < Error; end

  # Errores 4xx (Culpa del Cliente)
  class ClientError < Error; end

  # Errores 5xx (Culpa del Servidor)
  class ServerError < Error; end

  # === Errores Específicos 4xx ===
  class BadRequest < ClientError; end      # 400
  class NotFound < ClientError; end        # 404
  class NotAcceptable < ClientError; end   # 406
  class RequestTimeout < ClientError; end  # 408 (Timeout HTTP/RPC)

  # === Errores Específicos 5xx ===
  class InternalServerError < ServerError; end # 500

  # === Error de Validación (422) ===
  # Este es especial porque parsea el body para extraer los mensajes de error
  class UnprocessableEntity < ClientError
    attr_reader :error_messages, :raw_response

    def initialize(response_body)
      @raw_response = response_body
      @error_messages = parse_errors(response_body)
      super('Validation failed on remote service')
    end

    private

    def parse_errors(body)
      return body if body.is_a?(Hash)

      JSON.parse(body) rescue {}
    end
  end
end
