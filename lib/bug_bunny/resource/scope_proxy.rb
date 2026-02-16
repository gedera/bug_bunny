# frozen_string_literal: true

module BugBunny
  class Resource
    # Proxy para encadenamiento de métodos con contexto temporal.
    # Permite sintaxis como: User.with(routing_key: 'x').find(1).
    #
    # @api private
    class ScopeProxy < BasicObject
      # @param target [Class] La clase Resource original.
      # @param keys [Hash] Mapa de claves de thread originales a temporales.
      # @param old_values [Hash] Valores anteriores para restaurar.
      def initialize(target, keys, old_values)
        @target = target
        @keys = keys
        @old_values = old_values
      end

      # Delega cualquier método al target, restaurando el contexto al finalizar.
      def method_missing(method, *args, &block)
        @target.public_send(method, *args, &block)
      ensure
        restore_context
      end

      # Cumple con el contrato de Ruby para objetos delegados.
      def respond_to_missing?(method, include_private = false)
        @target.respond_to?(method, include_private) || super
      end

      private

      def restore_context
        @keys.each { |k, v| ::Thread.current[v] = @old_values[k] }
      end
    end
  end
end
