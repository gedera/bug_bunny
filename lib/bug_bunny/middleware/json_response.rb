# lib/bug_bunny/middleware/json_response.rb
require 'json'

module BugBunny
  module Middleware
    # Middleware encargado de parsear automáticamente el cuerpo de la respuesta.
    #
    # Este middleware intercepta la respuesta proveniente del servicio remoto. Si el `body`
    # es un String JSON válido, lo convierte a un Hash o Array de Ruby.
    #
    # **Integración con Rails:**
    # Si `ActiveSupport` está cargado en el entorno, convierte los Hashes resultantes
    # a `HashWithIndifferentAccess`. Esto permite a los desarrolladores acceder a las claves
    # usando símbolos o strings indistintamente (ej: `body[:id]` o `body['id']`),
    # comportamiento estándar en Rails.
    #
    # @example Uso en la configuración del cliente
    #   client = BugBunny::Client.new(pool: POOL) do |conn|
    #     # Se recomienda ponerlo después de RaiseError para tener el body parseado en las excepciones
    #     conn.use BugBunny::Middleware::RaiseError
    #     conn.use BugBunny::Middleware::JsonResponse
    #   end
    class JsonResponse
      # Inicializa el middleware.
      #
      # @param app [Object] El siguiente middleware o el productor final en el stack.
      def initialize(app)
        @app = app
      end

      # Ejecuta el middleware.
      #
      # Invoca al siguiente eslabón (`@app.call`) y espera su retorno.
      # Una vez recibida la respuesta, procesa el `body` antes de devolverla hacia arriba en la cadena.
      #
      # @param env [BugBunny::Request] El objeto request actual (el entorno).
      # @return [Hash] La respuesta con el campo 'body' transformado (si era JSON).
      def call(env)
        response = @app.call(env)
        # Parseamos el body DESPUÉS de recibir la respuesta (Post-processing)
        response['body'] = parse_body(response['body'])
        response
      end

      # Intenta convertir el cuerpo de la respuesta a una estructura Ruby nativa.
      #
      # @param body [String, Hash, Array, nil] El cuerpo original de la respuesta.
      # @return [Object] El cuerpo parseado (Hash/Array) o el objeto original si falla el parseo.
      # @api private
      def parse_body(body)
        return nil if body.nil? || body.empty?

        # Si ya es un objeto (ej: tests o mocks), lo dejamos pasar, si es String intentamos parsear.
        parsed = body.is_a?(String) ? JSON.parse(body) : body

        # Rails Magic: Indifferent Access
        # Si estamos en un entorno Rails, aplicamos la conversión para UX del desarrollador.
        if defined?(ActiveSupport)
          if parsed.is_a?(Array)
            parsed.map! { |e| e.try(:with_indifferent_access) || e }
          elsif parsed.is_a?(Hash)
            parsed = parsed.with_indifferent_access
          end
        end

        parsed
      rescue JSON::ParserError
        # Si el body no es un JSON válido (ej: texto plano o error del servidor),
        # devolvemos el string original sin lanzar excepción.
        body
      end
    end
  end
end
