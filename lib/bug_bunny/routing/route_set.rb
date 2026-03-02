# frozen_string_literal: true

require_relative 'route'

module BugBunny
  module Routing
    # Gestiona la colección de rutas de la aplicación y expone el DSL de configuración.
    #
    # Actúa como el motor principal del enrutador. Permite definir rutas de forma
    # declarativa (estilo Rails) e incluye macros convenientes como `resources` para
    # generar automáticamente las rutas CRUD estándar.
    #
    # @example Configuración del DSL
    #   route_set = RouteSet.new
    #   route_set.draw do
    #     get 'ping', to: 'health#ping'
    #     resources :nodes
    #   end
    class RouteSet
      # @return [Array<BugBunny::Routing::Route>] Lista de rutas registradas.
      attr_reader :routes

      # Inicializa un conjunto de rutas vacío.
      def initialize
        @routes = []
      end

      # Evalúa un bloque de código en el contexto de esta instancia para construir el mapa.
      #
      # @yield Bloque de configuración conteniendo el DSL de ruteo.
      # @return [void]
      def draw(&block)
        instance_eval(&block)
      end

      # Borra todas las rutas registradas (útil para tests o recarga en caliente).
      # @return [void]
      def clear!
        @routes.clear
      end

      # @!group DSL de Verbos HTTP

      # Registra una ruta para el verbo GET.
      # @param path [String] Patrón de la URL.
      # @param to [String] Destino (controlador#accion).
      def get(path, to:)
        add_route('GET', path, to: to)
      end

      # Registra una ruta para el verbo POST.
      # @param path [String] Patrón de la URL.
      # @param to [String] Destino (controlador#accion).
      def post(path, to:)
        add_route('POST', path, to: to)
      end

      # Registra una ruta para el verbo PUT.
      # @param path [String] Patrón de la URL.
      # @param to [String] Destino (controlador#accion).
      def put(path, to:)
        add_route('PUT', path, to: to)
      end

      # Registra una ruta para el verbo PATCH.
      # @param path [String] Patrón de la URL.
      # @param to [String] Destino (controlador#accion).
      def patch(path, to:)
        add_route('PATCH', path, to: to)
      end

      # Registra una ruta para el verbo DELETE.
      # @param path [String] Patrón de la URL.
      # @param to [String] Destino (controlador#accion).
      def delete(path, to:)
        add_route('DELETE', path, to: to)
      end

      # @!endgroup

      # Macro que genera automáticamente las 5 rutas CRUD para un recurso RESTful.
      #
      # Mapea las acciones: index (GET), show (GET /:id), create (POST),
      # update (PUT/PATCH /:id) y destroy (DELETE /:id).
      #
      # @param name [Symbol, String] Nombre del recurso en plural (ej. :nodes).
      # @return [void]
      # @example
      #   resources :services
      def resources(name)
        resource_path = name.to_s

        get    resource_path,         to: "#{resource_path}#index"
        post   resource_path,         to: "#{resource_path}#create"
        get    "#{resource_path}/:id", to: "#{resource_path}#show"
        put    "#{resource_path}/:id", to: "#{resource_path}#update"
        patch  "#{resource_path}/:id", to: "#{resource_path}#update"
        delete "#{resource_path}/:id", to: "#{resource_path}#destroy"
      end

      # Evalúa una petición entrante contra el mapa de rutas.
      #
      # Recorre las rutas en el orden en que fueron definidas. La primera ruta que
      # haga match será la ganadora. Retorna los datos necesarios para instanciar
      # el controlador e inyectarle los parámetros dinámicos extraídos.
      #
      # @param method [String] Verbo HTTP entrante.
      # @param path [String] URL entrante.
      # @return [Hash, nil] Hash con `:controller`, `:action` y `:params`, o `nil` si no hay match.
      def recognize(method, path)
        @routes.each do |route|
          if route.match?(method, path)
            extracted_params = route.extract_params(path)

            return {
              controller: route.controller,
              action: route.action,
              params: extracted_params
            }
          end
        end

        # Si llegamos aquí, es un 404 seguro.
        nil
      end

      private

      # Instancia y almacena la ruta en la colección.
      # @api private
      def add_route(method, path, to:)
        @routes << Route.new(method, path, to: to)
      end
    end
  end
end
