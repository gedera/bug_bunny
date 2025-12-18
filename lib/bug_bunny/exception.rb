# lib/bug_bunny/exception.rb
module BugBunny
  # Clase base para todas las excepciones lanzadas por BugBunny.
  # Permite rescatar cualquier error de la gema con `rescue BugBunny::Error`.
  class Error < ::StandardError; end

  # Error lanzado cuando hay fallos de red o de infraestructura con RabbitMQ.
  # (Ej: Broker caído, Timeout de conexión TCP).
  # Ideal para estrategias de reintento automático.
  class CommunicationError < Error; end

  # Clase base para errores HTTP 4xx (Client Errors).
  # Indica que la solicitud fue rechazada por el servidor debido a datos inválidos o estado incorrecto.
  class ClientError < Error; end

  # Clase base para errores HTTP 5xx (Server Errors).
  # Indica que el servidor remoto falló al procesar una solicitud válida.
  class ServerError < Error; end

  # === Subclases Específicas ===
  # HTTP 400 Bad Request
  class BadRequest < ClientError; end

  # HTTP 404 Not Found
  class NotFound < ClientError; end

  # HTTP 406 Not Acceptable
  class NotAcceptable < ClientError; end

  # HTTP 408 Request Timeout
  class RequestTimeout < ClientError; end

  # HTTP 500 Internal Server Error
  class InternalServerError < ServerError; end

  # Error HTTP 422 Unprocessable Entity.
  # Se utiliza principalmente para errores de validación de negocio.
  # Parsea automáticamente el cuerpo de la respuesta para extraer mensajes de error.
  class UnprocessableEntity < ClientError
    # @return [Hash] Hash con los errores parseados (ej: `{ email: ["is invalid"] }`).
    attr_reader :error_messages, :raw_response

    # @return [String] El cuerpo crudo de la respuesta.
    attr_reader :raw_response

    # @param response_body [String, Hash] El cuerpo de la respuesta (JSON o Hash).
    def initialize(response_body)
      @raw_response = response_body
      @error_messages = parse_errors(response_body)
      super('Validation failed on remote service')
    end

    private

    # @api private
    def parse_errors(body)
      return body if body.is_a?(Hash)
      return {} if body.blank?

      JSON.parse(body)
    rescue JSON::ParserError
      {}
    end
  end
end
