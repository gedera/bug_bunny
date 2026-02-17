# lib/bug_bunny/middleware/json_response.rb
# frozen_string_literal: true

require 'json'
require_relative '../middleware/base'

module BugBunny
  module Middleware
    # Middleware encargado de parsear automáticamente el cuerpo de la respuesta.
    #
    # Convierte strings JSON en Hashes de Ruby. Si está disponible ActiveSupport,
    # aplica HashWithIndifferentAccess.
    #
    # @see BugBunny::Middleware::Base
    class JsonResponse < BugBunny::Middleware::Base
      # Hook de ciclo de vida: Ejecutado después de recibir la respuesta.
      #
      # Intercepta el body y lo reemplaza por su versión parseada.
      #
      # @param response [Hash] La respuesta cruda.
      # @return [void]
      def on_complete(response)
        response['body'] = parse_body(response['body'])
      end

      private

      # Intenta convertir el cuerpo de la respuesta a una estructura Ruby nativa.
      #
      # @param body [String, Hash, Array, nil] El cuerpo original.
      # @return [Object] El cuerpo parseado o el original si falla.
      def parse_body(body)
        return nil if body.nil? || (body.respond_to?(:empty?) && body.empty?)

        # Si ya es un objeto (ej: mocks), lo dejamos pasar; si es String, parseamos.
        parsed = body.is_a?(String) ? safe_json_parse(body) : body

        # Rails Magic: Indifferent Access
        apply_indifferent_access(parsed)
      end

      # Parsea JSON de forma segura, retornando el original si falla.
      def safe_json_parse(json_string)
        JSON.parse(json_string)
      rescue JSON::ParserError
        json_string
      end

      # Aplica ActiveSupport::HashWithIndifferentAccess si es posible.
      def apply_indifferent_access(data)
        return data unless defined?(ActiveSupport)

        if data.is_a?(Array)
          data.map! { |e| e.try(:with_indifferent_access) || e }
        elsif data.is_a?(Hash)
          data.with_indifferent_access
        else
          data
        end
      end
    end
  end
end
