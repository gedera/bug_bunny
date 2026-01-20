# lib/bug_bunny/middleware/json_response.rb
module BugBunny
  module Middleware
    class JsonResponse
      def initialize(app)
        @app = app
      end

      def call(env)
        response = @app.call(env)
        # Parseamos el body DESPUÉS de recibir la respuesta
        response['body'] = parse_body(response['body'])
        response
      end

      def parse_body(body)
        return nil if body.nil? || body.empty?

        parsed = body.is_a?(String) ? JSON.parse(body) : body

        # Rails Magic: Indifferent Access
        if defined?(ActiveSupport)
          if parsed.is_a?(Array)
            parsed.map! { |e| e.try(:with_indifferent_access) || e }
          elsif parsed.is_a?(Hash)
            parsed = parsed.with_indifferent_access
          end
        end

        parsed
      rescue JSON::ParserError
        body # Si falla, devolvemos el string original
      end
    end
  end
end
