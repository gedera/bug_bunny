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
        when 200..299
          return # Flujo normal (Success)
        when 400
          raise BugBunny::BadRequest, format_error_message(body)
        when 404
          raise BugBunny::NotFound
        when 406
          raise BugBunny::NotAcceptable
        when 408
          raise BugBunny::RequestTimeout
        when 409
          raise BugBunny::Conflict, format_error_message(body)
        when 422
          # Pasamos el body crudo; UnprocessableEntity lo procesará en exception.rb
          raise BugBunny::UnprocessableEntity, body
        when 500..599
          raise BugBunny::InternalServerError, format_error_message(body)
        else
          handle_unknown_error(status, body)
        end
      end

      private

      # Formatea el cuerpo de la respuesta de error para que sea legible en las excepciones.
      #
      # Prioriza la convención `{ "error": "...", "detail": "..." }`. Si la respuesta no
      # sigue esta convención, convierte el Hash completo a un JSON string para mantenerlo legible.
      #
      # @param body [Hash, String, nil] El cuerpo de la respuesta.
      # @return [String] Un mensaje de error limpio y estructurado.
      def format_error_message(body)
        return "Unknown Error" if body.nil? || (body.respond_to?(:empty?) && body.empty?)
        return body if body.is_a?(String)

        # Si el worker devolvió un JSON con una key 'error' (nuestra convención en Controller)
        if body.is_a?(Hash) && body['error']
          detail = body['detail'] ? " - #{body['detail']}" : ""
          "#{body['error']}#{detail}"
        else
          # Fallback: Convertir todo el Hash a JSON string para que se vea claro en Sentry/Logs
          body.to_json
        end
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
          raise BugBunny::ServerError, "Server Error (#{status}): #{msg}"
        elsif status >= 400
          raise BugBunny::ClientError, "Client Error (#{status}): #{msg}"
        end
      end
    end
  end
end
