# frozen_string_literal: true

require 'rack/utils'

module BugBunny
  class Resource
    # Módulo que agrupa los métodos de consulta y factory methods (Finders).
    module Querying
      # Busca recursos que coincidan con los filtros dados.
      #
      # @param filters [Hash] Filtros para la query string.
      # @return [Array<BugBunny::Resource>] Lista de recursos encontrados.
      def where(filters = {})
        path = build_query_path(filters)
        rk = calculate_routing_key
        response = bug_bunny_client.request(path, method: :get, exchange: current_exchange,
                                                  exchange_type: current_exchange_type, routing_key: rk)

        return [] unless response['body'].is_a?(Array)

        response['body'].map { |attrs| instantiate_from_response(attrs) }
      end

      # Retorna todos los recursos.
      # @return [Array<BugBunny::Resource>]
      def all
        where({})
      end

      # Busca un recurso por su ID.
      #
      # @param id [String, Integer] El ID del recurso.
      # @return [BugBunny::Resource, nil] La instancia o nil si no existe (404).
      def find(id)
        rk = calculate_routing_key(id)
        path = "#{resource_name}/#{id}"
        response = bug_bunny_client.request(path, method: :get, exchange: current_exchange,
                                                  exchange_type: current_exchange_type, routing_key: rk)

        return nil if response.nil? || response['status'] == 404
        return nil unless response['body'].is_a?(Hash)

        instantiate_from_response(response['body'])
      end

      # Crea y guarda un nuevo recurso inmediatamente.
      # @param payload [Hash] Atributos del recurso.
      # @return [BugBunny::Resource] La instancia creada.
      def create(payload)
        new(payload).tap(&:save)
      end

      # Instancia un objeto desde una respuesta cruda, marcándolo como persistido.
      # @api private
      def instantiate_from_response(attrs)
        new(attrs).tap do |inst|
          inst.persisted = true
          inst.send(:clear_changes_information)
        end
      end

      private

      def build_query_path(filters)
        path = resource_name
        path += "?#{Rack::Utils.build_nested_query(filters)}" if filters.present?
        path
      end
    end
  end
end
