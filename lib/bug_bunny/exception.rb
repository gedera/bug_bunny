# frozen_string_literal: true

require 'json'

module BugBunny
  # Clase base para todas las excepciones lanzadas por la gema BugBunny.
  # Permite capturar cualquier error de la librería con un `rescue BugBunny::Error`.
  class Error < ::StandardError; end

  # Error lanzado cuando ocurren problemas de red o conexión con RabbitMQ.
  # Suele envolver excepciones nativas de la gema `bunny` (ej: TCP connection failure).
  class CommunicationError < Error; end

  # Error lanzado cuando ocurren un acceso no permitido a controladores.
  # Protege contra vulnerabilidades de RCE validando la herencia de las clases enrutadas.
  class SecurityError < Error; end

  # ==========================================
  # Categoría: Errores del Cliente (4xx)
  # ==========================================

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

  # Error 409: Conflict.
  # implica que la petición es técnicamente válida, pero choca con reglas de negocio o datos existentes
  class Conflict < ClientError; end

  # ==========================================
  # Categoría: Errores del Servidor (5xx)
  # ==========================================

  # Clase base para errores causados por fallos en el servidor remoto.
  # Corresponde a códigos de estado 500-599.
  class ServerError < Error; end

  # Error 500: Internal Server Error.
  # Ocurrió un error inesperado en el worker/servidor remoto al procesar el mensaje.
  class InternalServerError < ServerError; end

  # ==========================================
  # Categoría: Errores de Validación (422)
  # ==========================================

  # Error 422: Unprocessable Entity.
  # Indica que la solicitud fue bien formada pero contenía errores semánticos,
  # típicamente fallos de validación en el modelo remoto (ActiveRecord).
  #
  # Esta excepción es "inteligente": intenta parsear automáticamente el cuerpo 
  # de la respuesta para extraer y exponer los mensajes de error de forma estructurada,
  # buscando por convención la clave `errors`.
  class UnprocessableEntity < ClientError
    # @return [Hash, Array, String] Los mensajes de error listos para ser iterados.
    attr_reader :error_messages

    # @return [String, Hash] El cuerpo crudo de la respuesta original.
    attr_reader :raw_response

    # Inicializa la excepción procesando el cuerpo de la respuesta.
    #
    # @param response_body [String, Hash] El cuerpo de la respuesta fallida (ej. `{ "errors": { "name": ["blank"] } }`).
    def initialize(response_body)
      @raw_response = response_body
      @error_messages = extract_errors(response_body)
      super('Validation failed on remote service')
    end

    private

    # Intenta convertir el cuerpo de la respuesta a una estructura Ruby y extrae la clave 'errors'.
    # Si el cuerpo no sigue la convención o no es JSON, hace un graceful fallback devolviendo
    # el payload completo.
    #
    # @param body [String, Hash] El cuerpo a procesar.
    # @return [Object] Los errores aislados o el cuerpo original.
    # @api private
    def extract_errors(body)
      parsed = if body.is_a?(String)
                 begin
                   JSON.parse(body)
                 rescue JSON::ParserError
                   body # Si no es JSON, devolvemos el string tal cual
                 end
               else
                 body
               end

      if parsed.is_a?(Hash)
        # Extraemos inteligentemente la clave 'errors' si existe (convención típica de Rails)
        parsed['errors'] || parsed[:errors] || parsed
      else
        parsed
      end
    end
  end
end
