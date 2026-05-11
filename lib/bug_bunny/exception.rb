# frozen_string_literal: true

require 'json'

module BugBunny
  # Clase base para todas las excepciones lanzadas por la gema BugBunny.
  # Permite capturar cualquier error de la librería con un `rescue BugBunny::Error`.
  class Error < ::StandardError; end

  # Error lanzado cuando ocurren problemas de red o conexión con RabbitMQ.
  # Suele envolver excepciones nativas de la gema `bunny` (ej: TCP connection failure).
  class CommunicationError < Error; end

  # Error lanzado cuando la configuración de la gema es inválida.
  # Se levanta al final de {BugBunny.configure} si algún atributo no pasa las validaciones.
  class ConfigurationError < Error; end

  # Error lanzado cuando ocurren un acceso no permitido a controladores.
  # Protege contra vulnerabilidades de RCE validando la herencia de las clases enrutadas.
  class SecurityError < Error; end

  # Error lanzado cuando el broker responde NACK a una publicación en modo `:confirmed`.
  #
  # Un NACK significa que el broker rechazó explícitamente el mensaje (ej: política de
  # confirms interna, disk full, replicación insuficiente). El mensaje no fue aceptado
  # y se considera no entregado — equivalente a un fallo de transporte desde la
  # perspectiva del publisher.
  #
  # Se levanta por default desde {BugBunny::Producer#confirmed}. Para opt-out,
  # configurar `BugBunny.configuration.nack_raise = false` o pasar
  # `nack_raise: false` por request.
  #
  # @example
  #   rescue BugBunny::PublishNacked => e
  #     e.path         # => 'acct.start'
  #     e.nacked_count # => 1
  class PublishNacked < Error
    # @return [String] La ruta del request cuyo publish fue NACKeado.
    attr_reader :path

    # @return [Integer] Cantidad de mensajes NACKeados según `Bunny::Channel#nacked_set`.
    attr_reader :nacked_count

    # @param path [String] Ruta lógica del request (ej: 'acct.start').
    # @param nacked_count [Integer] Cantidad de NACKs reportados por el broker.
    def initialize(path:, nacked_count:)
      @path = path
      @nacked_count = nacked_count
      super("broker NACK on path=#{path} (nacked=#{nacked_count})")
    end
  end

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

  # Error 404 específico de enrutamiento.
  # Se lanza cuando el servicio remoto no tiene una ruta registrada para el verbo y path solicitados.
  # Análogo a `ActionController::RoutingError` en Rails.
  #
  # @example
  #   rescue BugBunny::RoutingError => e
  #     e.message # => 'No route matches [GET] "secrets"'
  class RoutingError < NotFound; end

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
