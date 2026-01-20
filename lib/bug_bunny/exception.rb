# lib/bug_bunny/exception.rb
require 'json'

module BugBunny
  # Clase base para todas las excepciones lanzadas por la gema BugBunny.
  # Permite capturar cualquier error de la librería con un `rescue BugBunny::Error`.
  class Error < ::StandardError; end

  # Error lanzado cuando ocurren problemas de red o conexión con RabbitMQ.
  # Suele envolver excepciones nativas de la gema `bunny` (ej: TCP connection failure).
  class CommunicationError < Error; end

  # === Categoría: Errores del Cliente (4xx) ===

  # Clase base para errores causados por una petición incorrecta del cliente.
  # Corresponde a códigos de estado 400-499.
  class ClientError < Error; end

  # Error 400: Bad Request.
  # La solicitud tiene una sintaxis incorrecta o no puede ser procesada por el servidor.
  class BadRequest < ClientError; end

  # Error 404: Not Found.
  # El recurso solicitado (o la ruta RPC) no existe en el servidor remoto.
  class NotFound < ClientError; end

  # Error 406: Not Acceptable.
  # El servidor no puede generar una respuesta con las características de contenido aceptadas.
  class NotAcceptable < ClientError; end

  # Error 408: Request Timeout.
  # El servidor tardó demasiado en responder o el cliente agotó su tiempo de espera (RPC timeout).
  class RequestTimeout < ClientError; end

  # === Categoría: Errores del Servidor (5xx) ===

  # Clase base para errores causados por fallos en el servidor remoto.
  # Corresponde a códigos de estado 500-599.
  class ServerError < Error; end

  # Error 500: Internal Server Error.
  # Ocurrió un error inesperado en el worker/servidor remoto al procesar el mensaje.
  class InternalServerError < ServerError; end

  # === Categoría: Errores de Validación (422) ===

  # Error 422: Unprocessable Entity.
  # Indica que la solicitud fue bien formada pero contenía errores semánticos,
  # típicamente fallos de validación en el modelo remoto (ActiveRecord).
  #
  # Esta excepción es especial porque intenta parsear automáticamente el cuerpo de la respuesta
  # para exponer los mensajes de error de forma estructurada.
  class UnprocessableEntity < ClientError
    # @return [Hash, Array] Los mensajes de error parseados desde la respuesta.
    attr_reader :error_messages

    # @return [String] El cuerpo crudo de la respuesta original.
    attr_reader :raw_response

    # Inicializa la excepción procesando el cuerpo de la respuesta.
    #
    # @param response_body [String, Hash] El cuerpo de la respuesta fallida.
    def initialize(response_body)
      @raw_response = response_body
      @error_messages = parse_errors(response_body)
      super('Validation failed on remote service')
    end

    private

    # Intenta convertir el cuerpo de la respuesta a una estructura Ruby (Hash/Array).
    # Si el cuerpo no es JSON válido, retorna un Hash vacío para evitar excepciones anidadas.
    #
    # @param body [String, Hash] El cuerpo a parsear.
    # @return [Object] El cuerpo parseado o un Hash vacío si falla.
    # @api private
    def parse_errors(body)
      return body if body.is_a?(Hash)

      JSON.parse(body)
    rescue JSON::ParserError
      {}
    end
  end
end
