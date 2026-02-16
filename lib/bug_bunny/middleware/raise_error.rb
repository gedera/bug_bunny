# frozen_string_literal: true

require_relative '../middleware'

module BugBunny
  module Middleware
    # Middleware que inspecciona el status de la respuesta y lanza excepciones
    # si se encuentran errores (4xx o 5xx).
    #
    # @see BugBunny::Middleware
    class RaiseError < BugBunny::Middleware
      # Errores que reciben el body como mensaje/argumento.
      ERRORS_WITH_BODY = {
        400 => BugBunny::BadRequest,
        422 => BugBunny::UnprocessableEntity,
        500 => BugBunny::InternalServerError
      }.freeze

      # Errores que se lanzan sin argumentos (usan mensaje default).
      ERRORS_WITHOUT_BODY = {
        404 => BugBunny::NotFound,
        406 => BugBunny::NotAcceptable,
        408 => BugBunny::RequestTimeout
      }.freeze

      private_constant :ERRORS_WITH_BODY, :ERRORS_WITHOUT_BODY

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
        return if (200..299).cover?(status)

        raise_mapped_error(status, response['body']) || handle_unknown_error(status)
      end

      private

      # Busca si el status tiene una excepción mapeada y la lanza.
      # @return [Boolean] true si se lanzó (interrumpiendo flujo), nil si no se encontró.
      def raise_mapped_error(status, body)
        if (klass = ERRORS_WITH_BODY[status])
          raise klass, body
        elsif (klass = ERRORS_WITHOUT_BODY[status])
          raise klass
        end
      end

      # Maneja errores 4xx/5xx genéricos no mapeados explícitamente.
      # @param status [Integer] El código de estado HTTP.
      # @raise [BugBunny::ClientError] Siempre lanza esta excepción si es >= 400.
      def handle_unknown_error(status)
        raise BugBunny::ClientError, "Unknown error: #{status}" if status >= 400
      end
    end
  end
end
