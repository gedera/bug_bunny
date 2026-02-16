# frozen_string_literal: true

# lib/bug_bunny/middleware/stack.rb

module BugBunny
  module Middleware
    # Gestiona una pila (stack) de middlewares para procesar peticiones y respuestas.
    #
    # Implementa el patrón "Builder" para construir una cadena de responsabilidades.
    # Permite registrar clases de middleware que envolverán la ejecución final (el Producer).
    # Es similar en funcionamiento a `Rack::Builder` o `Faraday::RackBuilder`.
    #
    # @example Construcción manual
    #   stack = BugBunny::Middleware::Stack.new
    #   stack.use BugBunny::Middleware::Logger
    #   stack.use BugBunny::Middleware::JsonResponse
    #
    #   # 'app' será el Logger, que llama a JsonResponse, que llama a final_producer
    #   app = stack.build(final_producer)
    #   app.call(request)
    class Stack
      # Inicializa una nueva pila de middlewares vacía.
      def initialize
        @middlewares = []
      end

      # Registra un middleware en la pila.
      #
      # @param klass [Class] La clase del middleware. Debe tener un constructor `initialize(app, *args)` y un método `call(env)`.
      # @param args [Array] Argumentos opcionales que se pasarán al constructor del middleware.
      # @yield [block] Bloque opcional que se pasará al constructor del middleware.
      # @return [Array] La lista actualizada de configuraciones de middleware.
      def use(klass, *args, &block)
        @middlewares << { klass: klass, args: args, block: block }
      end

      # Construye la cadena de ejecución (app) componiendo todos los middlewares registrados.
      #
      # Itera sobre los middlewares en orden inverso, envolviendo la `final_app` capa por capa.
      # Esto asegura que el primer middleware agregado con {#use} sea el más externo y, por tanto,
      # el primero en recibir la llamada `call`.
      #
      # @param final_app [Proc, Object] El objeto final que recibirá la petición (generalmente el Producer). Debe responder a `call`.
      # @return [Object] El primer eslabón de la cadena (el middleware más externo).
      def build(final_app)
        @middlewares.reverse.inject(final_app) do |app, config|
          config[:klass].new(app, *config[:args], &config[:block])
        end
      end
    end
  end
end
