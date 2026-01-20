# lib/bug_bunny/middleware/stack.rb
module BugBunny
  module Middleware
    class Stack
      def initialize
        @middlewares = []
      end

      # El famoso 'use' de Faraday
      # @param klass [Class] La clase del middleware
      # @param args [Array] Argumentos para el initialize del middleware
      # @param block [Proc] Bloque opcional configuración
      def use(klass, *args, &block)
        # Guardamos la definición para instanciarla después en cada request
        @middlewares << { klass: klass, args: args, block: block }
      end

      # Construye la cadena de ejecución (Onion pattern)
      # @param final_app [Lambda] La acción final (el Producer enviando el mensaje)
      def build(final_app)
        # Recorremos la lista al revés para envolver la app capa por capa
        @middlewares.reverse.inject(final_app) do |app, config|
          config[:klass].new(app, *config[:args], &config[:block])
        end
      end
    end
  end
end
