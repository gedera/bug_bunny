# frozen_string_literal: true

module BugBunny
  module Middleware
    # Gestiona una pila de middlewares (Chain of Responsibility).
    #
    # Permite apilar clases que interceptan y modifican las peticiones/respuestas
    # antes de llegar al Productor final, similar a Rack o Faraday.
    class Stack
      def initialize
        @middlewares = []
      end

      # Registra un middleware en la pila.
      #
      # @param klass [Class] La clase del middleware.
      #   Debe tener un constructor `initialize(app, *args)` y un método `call(env)`.
      # @param args [Array] Argumentos opcionales para el constructor del middleware.
      # @param block [Proc] Bloque opcional de configuración.
      def use(klass, *args, &block)
        @middlewares << { klass: klass, args: args, block: block }
      end

      # Construye la cadena de ejecución enlazando todos los middlewares.
      #
      # @param final_app [Proc, Object] El objeto final que recibirá la petición (generalmente el Producer).
      #   Debe responder a `call`.
      # @return [Object] El primer middleware de la cadena (el punto de entrada).
      def build(final_app)
        @middlewares.reverse.inject(final_app) do |app, config|
          config[:klass].new(app, *config[:args], &config[:block])
        end
      end
    end
  end
end
