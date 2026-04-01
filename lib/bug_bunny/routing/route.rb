# frozen_string_literal: true

module BugBunny
  module Routing
    # Representa una ruta individual dentro del mapa de rutas de BugBunny.
    #
    # Esta clase se encarga de compilar un patrón de URL (ej. 'users/:id') en una
    # Expresión Regular capaz de evaluar coincidencias y extraer los parámetros
    # dinámicos nombrados de forma automática.
    class Route
      # @return [String] El verbo HTTP de la ruta (GET, POST, PUT, DELETE).
      attr_reader :http_method

      # @return [String] El patrón original de la ruta (ej. 'nodes/:node_id/metrics').
      attr_reader :path_pattern

      # @return [String] El nombre del controlador en formato snake_case (ej. 'api/v1/metrics').
      attr_reader :controller

      # @return [String, nil] El namespace del controlador si existe (ej. 'Api::V1').
      attr_reader :namespace

      # @return [String] El nombre de la acción a ejecutar (ej. 'show').
      attr_reader :action

      # Inicializa una nueva Ruta compilando su Expresión Regular.
      #
      # @param http_method [String, Symbol] Verbo HTTP (ej. :get, 'POST').
      # @param path_pattern [String] Patrón de la URL. Los parámetros dinámicos deben iniciar con ':' (ej. 'users/:id').
      # @param to [String] Destino en formato 'controlador#accion' (ej. 'users#show').
      # @param namespace [String, nil] El namespace del controlador (ej: 'Api::V1').
      # @raise [ArgumentError] Si el formato del destino `to` es inválido.
      def initialize(http_method, path_pattern, to:, namespace: nil)
        @http_method = http_method.to_s.upcase
        @path_pattern = normalize_path(path_pattern)
        @namespace = namespace

        parse_destination!(to)
        compile_regex!
      end

      # Evalúa si una petición entrante coincide con esta ruta.
      #
      # @param method [String] El verbo HTTP entrante.
      # @param path [String] La URL entrante a evaluar.
      # @return [Boolean] `true` si hace match, `false` en caso contrario.
      def match?(method, path)
        return false unless @http_method == method.to_s.upcase

        normalized_path = normalize_path(path)
        @regex.match?(normalized_path)
      end

      # Extrae los parámetros dinámicos de una URL que hizo coincidencia con el patrón.
      #
      # @param path [String] La URL entrante (ej. 'users/123').
      # @return [Hash] Diccionario con las variables extraídas (ej. { 'id' => '123' }).
      # @example
      #   route = Route.new('GET', 'users/:id', to: 'users#show')
      #   route.extract_params('users/42') # => { 'id' => '42' }
      def extract_params(path)
        normalized_path = normalize_path(path)
        match_data = @regex.match(normalized_path)

        return {} unless match_data

        # match_data.named_captures devuelve un Hash con las variables que definimos en la Regex
        match_data.named_captures
      end

      private

      # Elimina las barras '/' al principio y al final para evitar problemas de formato.
      #
      # @param path [String] URL cruda.
      # @return [String] URL normalizada.
      def normalize_path(path)
        path.to_s.gsub(%r{^/|/$}, '')
      end

      # Parsea el string 'controlador#accion' y lo asigna a las variables de instancia.
      #
      # @param destination [String] El destino declarado por el usuario.
      def parse_destination!(destination)
        parts = destination.split('#')
        if parts.size != 2
          raise ArgumentError, "Destino inválido: '#{destination}'. Debe seguir el formato 'controlador#accion'."
        end

        @controller = parts[0]
        @action = parts[1]
      end

      # Transforma el string 'users/:id' en una Regex de Ruby con "Named Captures".
      # Reemplaza los :param por (?<param>[^/]+) que captura todo hasta la siguiente barra.
      def compile_regex!
        # Si la ruta es estática ('swarm/info'), la regex simplemente será /^swarm\/info$/
        # Si tiene variables ('nodes/:id'), convertimos el :id en un grupo de captura.
        pattern = @path_pattern.gsub(/:([a-zA-Z0-9_]+)/) do |match|
          param_name = match.delete(':')
          "(?<#{param_name}>[^/]+)"
        end

        @regex = Regexp.new("^#{pattern}$")
      end
    end
  end
end
