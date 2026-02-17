# lib/bug_bunny/middleware/raise_error.rb
# frozen_string_literal: true

require_relative '../middleware/base'

module BugBunny
  module Middleware
    # Middleware que inspecciona el status de la respuesta y lanza excepciones
    # si se encuentran errores (4xx o 5xx).
    #
    # @see BugBunny::Middleware::Base
    class RaiseError < BugBunny::Middleware::Base
      # Hook de ciclo de vida: Ejecutado después de recibir la respuesta.
      #
      # Verifica el código de estado y lanza la excepción correspondiente.
      #
      # @param response [Hash] El hash de respuesta conteniendo 'status' y 'body'.
      # @raise [BugBunny::ClientError] Si el status es 4xx.
      # @raise [BugBunny::ServerError] Si el status es 5xx.
      # @return [void]
      def on_complete(response)
        status = response['status'].to_i
        body = response['body']

        case status
        when 200..299
          nil # OK
        when 400 then raise BugBunny::BadRequest, body
        when 404 then raise BugBunny::NotFound
        when 406 then raise BugBunny::NotAcceptable
        when 408 then raise BugBunny::RequestTimeout
        when 422 then raise BugBunny::UnprocessableEntity, body
        when 500 then raise BugBunny::InternalServerError, body
        else
          handle_unknown_error(status)
        end
      end

      private

      # Maneja errores 4xx genéricos no mapeados explícitamente.
      # @param status [Integer] El código de estado HTTP.
      # @raise [BugBunny::ClientError] Siempre lanza esta excepción.
      def handle_unknown_error(status)
        raise BugBunny::ClientError, "Unknown error: #{status}" if status >= 400
      end
    end
  end
end
