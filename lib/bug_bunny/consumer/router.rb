# frozen_string_literal: true

require 'uri'
require 'rack/utils'

module BugBunny
  class Consumer
    # Módulo encargado de la lógica de enrutamiento (Routing).
    # Parsea la URL virtual y determina Controlador, Acción e ID.
    module Router
      # Parsea la URL virtual para determinar controlador, acción y parámetros.
      # @param method [String] Verbo HTTP (GET, POST, etc).
      # @param path [String] Ruta virtual (ej: users/123).
      # @return [Hash] Info de la ruta (:controller, :action, :id, :params).
      def router_dispatch(method, path)
        uri = URI.parse("http://dummy/#{path}")
        segments = parse_path_segments(uri.path)

        # Determinamos controlador, id y acción
        route = resolve_route_segments(method, segments)

        # Construimos los parámetros finales
        build_route_params(uri, route)
      end

      private

      def parse_path_segments(path)
        path.split('/').reject(&:empty?)
      end

      # Resuelve la ruta basándose en los segmentos y el verbo HTTP.
      def resolve_route_segments(method, segments)
        controller = segments[0]
        id = segments[1]
        action = segments[2] # Soporte para rutas miembro /controller/id/action

        # Si no hay acción explícita en la URL, la inferimos
        action ||= determine_rest_action(method, id)

        { controller: controller, action: action, id: id }
      end

      def determine_rest_action(method, id)
        case method.to_s.upcase
        when 'GET'            then id ? 'show' : 'index'
        when 'POST'           then 'create'
        when 'PUT', 'PATCH'   then 'update'
        when 'DELETE'         then 'destroy'
        else id || 'index'
        end
      end

      def build_route_params(uri, route)
        query_params = parse_query_params(uri.query)
        query_params['id'] = route[:id] if route[:id]

        {
          controller: route[:controller],
          action: route[:action],
          id: route[:id],
          params: query_params
        }
      end

      def parse_query_params(query_string)
        params = query_string ? Rack::Utils.parse_nested_query(query_string) : {}
        defined?(ActiveSupport::HashWithIndifferentAccess) ? params.with_indifferent_access : params
      end
    end
  end
end
