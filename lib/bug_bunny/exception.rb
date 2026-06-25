# frozen_string_literal: true

require 'json'

module BugBunny
  # Clase base para todas las excepciones lanzadas por la gema BugBunny.
  # Permite capturar cualquier error de la librería con un `rescue BugBunny::Error`.
  #
  # Para los errores derivados de una respuesta RPC (los que levanta
  # {BugBunny::Middleware::RaiseError}), expone de forma uniforme la **materia
  # prima** del error: el `status` y el `raw_response` (cuerpo crudo). La gema es
  # **agnóstica al payload**: no interpreta la estructura del cuerpo de error: es
  # el boundary de cada servicio quien lee `raw_response` y decide la semántica
  # de dominio (códigos, detalles de validación, etc.).
  #
  # @example Leer la materia prima en el boundary del servicio
  #   rescue BugBunny::Error => e
  #     e.status       # => 409
  #     e.raw_response # => { "error" => { "code" => "...", "message" => "...", "details" => {} } }
  class Error < ::StandardError
    # @return [Hash, String, nil] El cuerpo crudo de la respuesta de error, tal
    #   como llegó por el wire. `nil` para errores que no provienen de una
    #   respuesta RPC (ej: {CommunicationError}, {ConfigurationError}).
    #
    # @note **No loguear ni enviar a sinks (Sentry/logs) sin sanitizar.** El
    #   cuerpo crudo puede contener datos sensibles (p. ej. en `details`). Antes
    #   de cualquier sink, filtrar las claves sensibles del fleet
    #   (`password|pass|passwd|secret|token|api_key|auth`) → `[FILTERED]`. La
    #   gema entrega el cuerpo crudo a propósito; sanitizarlo es responsabilidad
    #   del consumidor.
    attr_accessor :raw_response

    # @return [Integer, nil] El código de estado de la respuesta que originó el
    #   error (ej: 400, 404, 409, 422, 500). `nil` para errores que no provienen
    #   de una respuesta RPC.
    attr_accessor :status
  end

  # Error lanzado cuando ocurren problemas de red, conexión o protocolo AMQP con RabbitMQ.
  #
  # Envuelve cualquier `Bunny::Exception` (TCP fail, auth fail, canal cerrado,
  # `PreconditionFailed`, `ConnectionClosedError`, etc.) en las fronteras de
  # abstracción del gem — `BugBunny.create_connection`, `BugBunny::Client#publish` /
  # `#request` / `#send`, y `BugBunny::Producer#confirmed`. Los callers no deberían
  # rescatar tipos de `Bunny::*` directamente: con `rescue BugBunny::CommunicationError`
  # alcanza para cubrir cualquier fallo de transporte/broker.
  #
  # La excepción original queda accesible vía `.cause` (Ruby la preserva
  # automáticamente al re-raisear dentro del `rescue`).
  #
  # @example
  #   begin
  #     client.publish('evt', exchange: 'x', body: payload)
  #   rescue BugBunny::CommunicationError => e
  #     logger.error("publish failed: #{e.message} cause=#{e.cause&.class}")
  #   end
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

  # Error lanzado cuando el broker retorna un mensaje publicado con `mandatory: true`
  # que no pudo rutearse a ninguna cola en modo `:confirmed`.
  #
  # Un return implica que el publish llegó al broker pero ninguna binding aceptó la
  # routing key — el mensaje se considera no entregado desde la perspectiva del
  # publisher. Espejo simétrico de {PublishNacked} pero para la señal `basic.return`
  # en lugar de `basic.nack`.
  #
  # Se levanta por default desde {BugBunny::Producer#confirmed} cuando el request
  # tiene `mandatory: true`. Para opt-out, configurar
  # `BugBunny.configuration.return_raise = false` o pasar `return_raise: false`
  # por request. El callback `BugBunny.configuration.on_return` se sigue invocando
  # antes del raise (orden: registro interno → user_cb → raise en el caller).
  #
  # @example
  #   rescue BugBunny::PublishUnroutable => e
  #     e.path           # => 'acct.start'
  #     e.exchange       # => 'acct_x'
  #     e.routing_key    # => 'acct.unbound'
  #     e.reply_code     # => 312
  #     e.reply_text     # => 'NO_ROUTE'
  #     e.correlation_id # => 'corr-uuid-...'
  class PublishUnroutable < Error
    # @return [String] Ruta lógica del request cuyo publish fue retornado.
    attr_reader :path

    # @return [String] Nombre del exchange destino.
    attr_reader :exchange

    # @return [String] Routing key utilizada en el publish.
    attr_reader :routing_key

    # @return [Integer, nil] Código AMQP de la razón (ej: 312 = NO_ROUTE).
    attr_reader :reply_code

    # @return [String, nil] Texto humano-legible que describe la razón.
    attr_reader :reply_text

    # @return [String, nil] Correlation ID del request retornado.
    attr_reader :correlation_id

    # @param path [String] Ruta lógica del request (ej: 'acct.start').
    # @param exchange [String] Nombre del exchange destino.
    # @param routing_key [String] Routing key del publish.
    # @param reply_code [Integer, nil] Código AMQP del return.
    # @param reply_text [String, nil] Texto del return.
    # @param correlation_id [String, nil] Correlation ID del mensaje retornado.
    # rubocop:disable Metrics/ParameterLists
    def initialize(path:, exchange:, routing_key:, reply_code: nil, reply_text: nil, correlation_id: nil)
      @path = path
      @exchange = exchange
      @routing_key = routing_key
      @reply_code = reply_code
      @reply_text = reply_text
      @correlation_id = correlation_id
      super("broker returned unroutable message on path=#{path} exchange=#{exchange} " \
            "routing_key=#{routing_key} reply_code=#{reply_code} reply_text=#{reply_text}")
    end
    # rubocop:enable Metrics/ParameterLists
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

    # `raw_response` y `status` se heredan de {BugBunny::Error} (poblados por
    # {BugBunny::Middleware::RaiseError}); `raw_response` además se setea acá en
    # el constructor para mantener el comportamiento histórico.

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
