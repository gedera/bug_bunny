# frozen_string_literal: true

require_relative 'base'

module BugBunny
  module Middleware
    # Middleware que inspecciona el status de la respuesta y lanza excepciones
    # si se encuentran errores (4xx o 5xx).
    #
    # Extrae inteligentemente el mensaje de error del cuerpo de la respuesta
    # para que las excepciones tengan trazas claras y legibles, evitando el
    # output crudo de Hashes en Ruby (`{ "error" => ... }`).
    #
    # @see BugBunny::Middleware::Base
    class RaiseError < BugBunny::Middleware::Base
      # Hook de ciclo de vida: Ejecutado después de recibir la respuesta.
      #
      # Verifica el código de estado (status) de la respuesta. Si cae en el rango
      # de éxito (2xx), permite que el flujo continúe. Si es un error, lo formatea
      # y lanza la excepción semántica correspondiente.
      #
      # @param response [Hash] El hash de respuesta conteniendo 'status' y 'body'.
      # @raise [BugBunny::BadRequest] Si el status es 400.
      # @raise [BugBunny::NotFound] Si el status es 404.
      # @raise [BugBunny::NotAcceptable] Si el status es 406.
      # @raise [BugBunny::RequestTimeout] Si el status es 408.
      # @raise [BugBunny::Conflict] Si el status es 409.
      # @raise [BugBunny::UnprocessableEntity] Si el status es 422.
      # @raise [BugBunny::InternalServerError] Si el status es 500..599.
      # @raise [BugBunny::ClientError, BugBunny::ServerError] Para códigos no mapeados.
      # @return [void]
      def on_complete(response)
        status = response['status'].to_i
        body = response['body']

        case status
        when 200..299 then nil # Flujo normal (Success)
        when 400 then raise_typed(BugBunny::BadRequest.new(format_error_message(body)), status, body)
        when 404 then raise_not_found(status, body)
        when 406 then raise_typed(BugBunny::NotAcceptable.new, status, body)
        when 408 then raise_typed(BugBunny::RequestTimeout.new, status, body)
        when 409 then raise_typed(BugBunny::Conflict.new(format_error_message(body)), status, body)
        # Pasamos el body crudo; UnprocessableEntity lo procesará en exception.rb
        when 422 then raise_typed(BugBunny::UnprocessableEntity.new(body), status, body)
        when 500..599 then raise_server_error(status, body)
        else handle_unknown_error(status, body)
        end
      end

      private

      # Levanta el error de servidor (5xx). Si el worker remoto serializó su
      # excepción en `bug_bunny_exception`, propaga un {BugBunny::RemoteError} con
      # la traza original; si no, un {BugBunny::InternalServerError} genérico.
      #
      # @param status [Integer] El código de estado (rango 500..599).
      # @param body [Hash, String, nil] El cuerpo crudo de la respuesta.
      # @raise [BugBunny::RemoteError] Si el cuerpo trae `bug_bunny_exception`.
      # @raise [BugBunny::InternalServerError] Para 5xx genéricos.
      def raise_server_error(status, body)
        if body.is_a?(Hash) && body['bug_bunny_exception']
          data = body['bug_bunny_exception']
          remote = BugBunny::RemoteError.new(data['class'], data['message'], data['backtrace'] || [])
          raise_typed(remote, status, body)
        end

        raise_typed(BugBunny::InternalServerError.new(format_error_message(body)), status, body)
      end

      # Puebla la materia prima del error (`status` + `raw_response`) en la
      # excepción y la levanta. Aplica de forma uniforme a **todas** las clases de
      # error derivadas de una respuesta RPC, no solo a {BugBunny::UnprocessableEntity}.
      #
      # La gema es agnóstica al payload: entrega el cuerpo crudo tal cual para que
      # el boundary del servicio lo interprete; no parsea su estructura.
      #
      # @param error [BugBunny::Error] La excepción ya construida.
      # @param status [Integer] El código de estado de la respuesta.
      # @param body [Hash, String, nil] El cuerpo crudo de la respuesta.
      # @raise [BugBunny::Error] Siempre levanta la excepción recibida.
      # @return [void]
      def raise_typed(error, status, body)
        error.status = status
        error.raw_response = body
        raise error
      end

      # Formatea el cuerpo de la respuesta de error en un **string humano**
      # best-effort para logs/Sentry. Es de mejor esfuerzo, **no un contrato**: la
      # gema no expone `code`/`details` como API; quien los necesite los lee desde
      # `raw_response` en el boundary del servicio.
      #
      # Soporta dos shapes del cuerpo, en orden de prioridad:
      #
      # 1. **Envelope anidado** `{ "error": { "message": "...", ... } }`: extrae
      #    `error.message`.
      # 2. **Shape plano** `{ "error": "texto", "detail": "..." }`: concatena
      #    `error` + `detail`.
      #
      # Si ninguno aplica, cae a `body.to_json` para no volcar un `Hash#inspect`
      # ilegible en los logs.
      #
      # @note Esta función **solo** arma el mensaje humano y no interpreta el
      #   detalle estructurado del cuerpo (claves como `code`/`details`/`detail`).
      #   Ese contenido vive en `raw_response` y lo interpreta el boundary del
      #   servicio; la gema se mantiene agnóstica al payload.
      #
      # @param body [Hash, String, nil] El cuerpo de la respuesta.
      # @return [String] Un mensaje de error limpio y legible.
      def format_error_message(body)
        return 'Unknown Error' if body.nil? || (body.respond_to?(:empty?) && body.empty?)
        return body if body.is_a?(String)
        return body.to_json unless body.is_a?(Hash)

        human_message_from(body) || body.to_json
      end

      # Extrae el string humano del cuerpo según el shape, sin volcar Hashes.
      #
      # @param body [Hash] El cuerpo de la respuesta.
      # @return [String, nil] El mensaje humano, o `nil` si el shape no lo provee.
      # @api private
      def human_message_from(body)
        err = body['error']

        # Envelope canónico anidado: { error: { message: "..." } }
        if err.is_a?(Hash)
          nested = err['message']
          return nested if nested.is_a?(String) && !nested.empty?

          return nil
        end

        # Shape plano histórico: { error: "texto", detail: "..." }.
        # Cualquier String (incluido "") entra por acá para preservar el
        # comportamiento histórico (la key 'error' siempre fue truthy).
        return nil unless err.is_a?(String)

        detail = body['detail'] ? " - #{body['detail']}" : ''
        "#{err}#{detail}"
      end

      # Distingue un error de routing (ruta/controller no existe en el servicio remoto)
      # de un 404 genérico de recurso no encontrado.
      #
      # @param status [Integer] El código de estado (404).
      # @param body [Hash, String, nil] El cuerpo de la respuesta 404.
      # @raise [BugBunny::RoutingError] Si el consumer marcó `error_type: 'routing_error'`.
      # @raise [BugBunny::NotFound] Para 404 genéricos.
      def raise_not_found(status, body)
        if body.is_a?(Hash) && body['error_type'] == 'routing_error'
          raise_typed(BugBunny::RoutingError.new(format_error_message(body)), status, body)
        end

        raise_typed(BugBunny::NotFound.new(format_error_message(body)), status, body)
      end

      # Maneja códigos de error genéricos no mapeados explícitamente en el `case`.
      #
      # @param status [Integer] El código de estado HTTP (ej. 418, 502).
      # @param body [Object] El cuerpo crudo de la respuesta.
      # @raise [BugBunny::ServerError] Si es 5xx.
      # @raise [BugBunny::ClientError] Si es 4xx.
      def handle_unknown_error(status, body)
        msg = format_error_message(body)

        if status >= 500
          raise_typed(BugBunny::ServerError.new("Server Error (#{status}): #{msg}"), status, body)
        elsif status >= 400
          raise_typed(BugBunny::ClientError.new("Client Error (#{status}): #{msg}"), status, body)
        end
      end
    end
  end
end
