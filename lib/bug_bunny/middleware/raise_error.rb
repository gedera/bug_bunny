# lib/bug_bunny/middleware/raise_error.rb
module BugBunny
  module Middleware
    # Middleware que inspecciona el status de la respuesta y lanza excepciones
    # si se encuentran errores (4xx o 5xx).
    #
    # Mapea los códigos de estado HTTP/AMQP a excepciones específicas de Ruby para facilitar
    # el manejo de errores mediante `rescue`.
    #
    # @note Orden de Middlewares:
    #   Se recomienda usar este middleware **antes** de `JsonResponse` si deseas que
    #   la excepción contenga el cuerpo ya parseado (Hash).
    #
    # @example Configuración recomendada
    #   client = BugBunny::Client.new(pool: POOL) do |conn|
    #     conn.use BugBunny::Middleware::RaiseError   # 1. Verifica errores primero (al salir)
    #     conn.use BugBunny::Middleware::JsonResponse # 2. Parsea JSON
    #   end
    class RaiseError
      # Inicializa el middleware.
      # @param app [Object] El siguiente middleware o la aplicación final.
      def initialize(app)
        @app = app
      end

      # Ejecuta el middleware.
      # Realiza la petición y, al retornar, verifica el estado de la respuesta.
      #
      # @param env [BugBunny::Request] El objeto request actual.
      # @return [Hash] La respuesta si el status es exitoso (2xx).
      # @raise [BugBunny::ClientError] Si el status es 4xx.
      # @raise [BugBunny::ServerError] Si el status es 5xx.
      def call(env)
        response = @app.call(env)
        on_complete(response)
        response
      end

      # Verifica el código de estado y lanza la excepción correspondiente.
      #
      # Mapeo de errores:
      # * 400 -> {BugBunny::BadRequest}
      # * 404 -> {BugBunny::NotFound}
      # * 406 -> {BugBunny::NotAcceptable}
      # * 408 -> {BugBunny::RequestTimeout}
      # * 422 -> {BugBunny::UnprocessableEntity}
      # * 500 -> {BugBunny::InternalServerError}
      # * Otros 4xx -> {BugBunny::ClientError}
      #
      # @param response [Hash] El hash de respuesta conteniendo 'status' y 'body'.
      # @return [void]
      def on_complete(response)
        status = response['status'].to_i
        body = response['body'] # Nota: Puede ser String o Hash dependiendo de JsonResponse

        case status
        when 200..299
          # OK: No action needed
        when 400 then raise BugBunny::BadRequest, body
        when 404 then raise BugBunny::NotFound
        when 406 then raise BugBunny::NotAcceptable
        when 408 then raise BugBunny::RequestTimeout
        when 422 then raise BugBunny::UnprocessableEntity, body
        when 500 then raise BugBunny::InternalServerError, body
        else
          raise BugBunny::ClientError, "Unknown error: #{status}" if status >= 400
        end
      end
    end
  end
end
