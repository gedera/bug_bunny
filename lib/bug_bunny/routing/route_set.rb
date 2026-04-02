# frozen_string_literal: true

require_relative 'route'

module BugBunny
  module Routing
    # Gestiona la colección de rutas de la aplicación y expone el DSL de configuración.
    #
    # Actúa como el motor principal del enrutador. Permite definir rutas de forma
    # declarativa (estilo Rails) e incluye macros convenientes como `resources`,
    # soportando bloques anidados `member` y `collection`.
    #
    # @example Configuración del DSL en un inicializador
    #   route_set = RouteSet.new
    #   route_set.draw do
    #     get 'ping', to: 'health#ping'
    #
    #     resources :nodes, except: [:create, :destroy] do
    #       member do
    #         put :drain
    #       end
    #       collection do
    #         get :stats
    #       end
    #     end
    #   end
    class RouteSet
      # @return [Array<BugBunny::Routing::Route>] Lista de rutas registradas y compiladas.
      attr_reader :routes

      # Inicializa un conjunto de rutas vacío y prepara el stack de scopes.
      def initialize
        @routes = []
        @scopes = [] # Pila para rastrear el contexto (namespaces, resources, members)
      end

      # Evalúa un bloque de código en el contexto de esta instancia para construir el mapa.
      # Utiliza `instance_eval` para exponer el DSL directamente.
      #
      # @yield Bloque de configuración conteniendo las definiciones de ruteo.
      # @return [void]
      def draw(&block)
        instance_eval(&block)
      end

      # Borra todas las rutas registradas y limpia los scopes.
      # Es útil para entornos de pruebas (testing) o recarga en caliente (hot-reloading).
      #
      # @return [void]
      def clear!
        @routes.clear
        @scopes.clear
      end

      # @!group DSL de Verbos HTTP

      # Registra una ruta para el verbo GET.
      # @param path [String, Symbol] Patrón de la URL.
      # @param to [String, nil] Destino (controlador#accion). Si es nil, se infiere del scope.
      def get(path, to: nil)
        add_route('GET', path, to: to)
      end

      # Registra una ruta para el verbo POST.
      # @param path [String, Symbol] Patrón de la URL.
      # @param to [String, nil] Destino (controlador#accion). Si es nil, se infiere del scope.
      def post(path, to: nil)
        add_route('POST', path, to: to)
      end

      # Registra una ruta para el verbo PUT.
      # @param path [String, Symbol] Patrón de la URL.
      # @param to [String, nil] Destino (controlador#accion). Si es nil, se infiere del scope.
      def put(path, to: nil)
        add_route('PUT', path, to: to)
      end

      # Registra una ruta para el verbo PATCH.
      # @param path [String, Symbol] Patrón de la URL.
      # @param to [String, nil] Destino (controlador#accion). Si es nil, se infiere del scope.
      def patch(path, to: nil)
        add_route('PATCH', path, to: to)
      end

      # Registra una ruta para el verbo DELETE.
      # @param path [String, Symbol] Patrón de la URL.
      # @param to [String, nil] Destino (controlador#accion). Si es nil, se infiere del scope.
      def delete(path, to: nil)
        add_route('DELETE', path, to: to)
      end

      # @!endgroup

      # Define un bloque de namespace para organizar controladores en módulos.
      # Los namespaces pueden anidarse y se acumulan (ej: `namespace :api { namespace :v1 }`
      # resulta en el namespace "Api::V1").
      #
      # @param name [Symbol, String] Nombre del namespace (ej: :api, :v1).
      # @yield Bloque conteniendo las definiciones de rutas dentro de este namespace.
      # @return [void]
      # @example
      #   namespace :api do
      #     resources :users # Busca Api::UsersController
      #   end
      def namespace(name, &block)
        with_scope({ type: :namespace, name: name.to_s.camelize }) do
          instance_eval(&block)
        end
      end

      # Macro que genera automáticamente las rutas CRUD para un recurso RESTful.
      # Soporta filtrado mediante `only` y `except`, y acepta un bloque para rutas anidadas.
      #
      # Mapea las acciones: index (GET), show (GET /:id), create (POST),
      # update (PUT/PATCH /:id) y destroy (DELETE /:id).
      #
      # @param name [Symbol, String] Nombre del recurso en plural (ej. :nodes).
      # @param only [Array<Symbol>, Symbol, nil] Acciones a incluir exclusivamente.
      # @param except [Array<Symbol>, Symbol, nil] Acciones a excluir.
      # @yield Bloque para definir rutas `member` o `collection`.
      # @return [void]
      def resources(name, only: nil, except: nil, &block)
        resource_path = name.to_s

        # Todas las acciones estándar disponibles
        actions = %i[index show create update destroy]

        # Aplicamos los filtros si existen
        if only
          actions &= Array(only).map(&:to_sym)
        elsif except
          actions -= Array(except).map(&:to_sym)
        end

        # Rutas estándar (Fuera del scope anidado)
        get    resource_path,          to: "#{resource_path}#index"   if actions.include?(:index)
        post   resource_path,          to: "#{resource_path}#create"  if actions.include?(:create)
        get    "#{resource_path}/:id", to: "#{resource_path}#show"    if actions.include?(:show)
        put    "#{resource_path}/:id", to: "#{resource_path}#update"  if actions.include?(:update)
        patch  "#{resource_path}/:id", to: "#{resource_path}#update"  if actions.include?(:update)
        delete "#{resource_path}/:id", to: "#{resource_path}#destroy" if actions.include?(:destroy)

        # Si se pasa un bloque, abrimos un Scope de Recurso para rutas anidadas
        return unless block_given?

        with_scope({ type: :resource, name: resource_path }) do
          instance_eval(&block)
        end
      end

      # Define rutas aplicables a un miembro específico del recurso (Requieren un ID).
      #
      # Al usar este bloque, el router antepondrá automáticamente el nombre del recurso
      # y el parámetro `:id` a la URL generada, e inferirá el controlador base.
      #
      # @yield Bloque conteniendo definiciones de rutas.
      # @raise [ArgumentError] Si se llama fuera de un bloque `resources`.
      # @return [void]
      # @example
      #   resources :nodes do
      #     member do
      #       put :drain # Genera: PUT nodes/:id/drain => NodesController#drain
      #     end
      #   end
      def member(&block)
        unless current_scope[:type] == :resource
          raise ArgumentError, "El bloque 'member' solo puede usarse dentro de un bloque 'resources'"
        end

        with_scope({ type: :member }) do
          instance_eval(&block)
        end
      end

      # Define rutas aplicables a la colección completa del recurso (Sin ID).
      #
      # Al usar este bloque, el router antepondrá automáticamente el nombre del recurso
      # a la URL generada e inferirá el controlador base.
      #
      # @yield Bloque conteniendo definiciones de rutas.
      # @raise [ArgumentError] Si se llama fuera de un bloque `resources`.
      # @return [void]
      # @example
      #   resources :nodes do
      #     collection do
      #       get :stats # Genera: GET nodes/stats => NodesController#stats
      #     end
      #   end
      def collection(&block)
        unless current_scope[:type] == :resource
          raise ArgumentError, "El bloque 'collection' solo puede usarse dentro de un bloque 'resources'"
        end

        with_scope({ type: :collection }) do
          instance_eval(&block)
        end
      end

      # Evalúa una petición entrante contra el mapa de rutas.
      #
      # Recorre las rutas en el orden en que fueron definidas. La primera ruta que
      # haga match será la ganadora. Retorna los datos necesarios para instanciar
      # el controlador e inyectarle los parámetros dinámicos extraídos.
      #
      # @param method [String] Verbo HTTP entrante (ej. 'GET').
      # @param path [String] URL entrante (ej. 'nodes/123/drain').
      # @return [Hash, nil] Hash con `:controller`, `:action`, `:params` y `:namespace`, o `nil` si no hay match.
      def recognize(method, path)
        @routes.each do |route|
          next unless route.match?(method, path)

          extracted_params = route.extract_params(path)

          return {
            controller: route.controller,
            action: route.action,
            params: extracted_params,
            namespace: route.namespace
          }
        end

        # Si llegamos aquí, es un 404 seguro.
        nil
      end

      private

      # Instancia y almacena la ruta resolviendo la URL final y el controlador según el scope.
      #
      # @param method [String] Verbo HTTP.
      # @param path [String, Symbol] Ruta declarada.
      # @param to [String, nil] Destino declarado.
      # @raise [ArgumentError] Si no se puede inferir el destino y no se provee uno.
      # @api private
      def add_route(method, path, to: nil)
        final_path = path.to_s
        final_to = to

        # Inferimos rutas basadas en el Scope Activo
        if in_scope?(:member)
          resource = parent_resource_name
          final_path = "#{resource}/:id/#{path}"
          final_to ||= "#{resource}##{path}"
        elsif in_scope?(:collection) || in_scope?(:resource)
          resource = parent_resource_name
          final_path = "#{resource}/#{path}"
          final_to ||= "#{resource}##{path}"
        end

        if final_to.nil?
          raise ArgumentError,
                "Falta el destino 'to:' para la ruta #{method} '#{final_path}'. Usa la sintaxis 'controlador#accion'"
        end

        @routes << Route.new(method, final_path, to: final_to, namespace: current_namespace)
      end

      # --- LÓGICA DE SCOPES INTERNOS ---

      # Abre un nuevo contexto de alcance temporal.
      #
      # @param scope [Hash] Información del nuevo alcance.
      # @yield Bloque a ejecutar dentro de este alcance.
      # @api private
      def with_scope(scope)
        @scopes << scope
        yield
      ensure
        @scopes.pop
      end

      # @return [Hash] El scope activo actualmente.
      # @api private
      def current_scope
        @scopes.last || {}
      end

      # @param type [Symbol] El tipo de scope a verificar.
      # @return [Boolean] Si estamos dentro de un scope del tipo especificado.
      # @api private
      def in_scope?(type)
        current_scope[:type] == type
      end

      # Busca hacia atrás en la pila de scopes para encontrar el nombre del recurso padre.
      #
      # @return [String, nil] El nombre del recurso o nil si no se encuentra.
      # @api private
      def parent_resource_name
        @scopes.reverse_each do |scope|
          return scope[:name] if scope[:type] == :resource
        end
        nil
      end

      # Calcula el namespace acumulado recorriendo la pila de scopes.
      #
      # @return [String, nil] El namespace (ej: "Api::V1") o nil si no hay.
      # @api private
      def current_namespace
        parts = @scopes.select { |s| s[:type] == :namespace }.map { |s| s[:name] }
        parts.empty? ? nil : parts.join('::')
      end
    end
  end
end
