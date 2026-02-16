# frozen_string_literal: true

module BugBunny
  class Resource
    # Módulo para la configuración de la conexión, enrutamiento y gestión de hilos.
    # Se encarga de resolver qué Exchange, Routing Key y Pool de conexiones usar
    # en cada momento (contexto estático o dinámico vía `.with`).
    module Configuration
      # @!attribute [w] connection_pool
      #   @return [ConnectionPool] Pool de conexiones asignado al recurso.
      attr_writer :connection_pool, :exchange, :exchange_type, :resource_name, :routing_key, :param_key

      # Obtiene una configuración específica del thread actual (Contexto Dinámico).
      # @api private
      # @param key [Symbol] La clave de configuración (:routing_key, :exchange, etc).
      # @return [Object, nil] El valor configurado en el thread o nil.
      def thread_config(key)
        Thread.current["bb_#{object_id}_#{key}"]
      end

      # Resuelve el valor de una configuración siguiendo la jerarquía:
      # 1. Thread (Scope dinámico `.with`).
      # 2. Variable de instancia de la Clase.
      # 3. Herencia (Superclase).
      #
      # @api private
      # @param key [Symbol] Clave para buscar en el thread.
      # @param ivar [Symbol] Nombre de la variable de instancia (ej: :@exchange).
      # @return [Object, nil] El valor resuelto.
      def resolve_config(key, ivar)
        val = thread_config(key)
        return val if val

        target = self
        while target <= BugBunny::Resource
          val = target.instance_variable_get(ivar)
          return val.respond_to?(:call) ? val.call : val unless val.nil?

          target = target.superclass
        end
        nil
      end

      # @return [ConnectionPool] El pool de conexiones activo.
      def connection_pool
        resolve_config(:pool, :@connection_pool)
      end

      # @return [String] Nombre del exchange actual.
      # @raise [ArgumentError] Si no se ha definido un exchange.
      def current_exchange
        resolve_config(:exchange, :@exchange) || raise(ArgumentError, 'Exchange not defined')
      end

      # @return [String] Tipo de exchange ('direct', 'topic', etc). Default: 'direct'.
      def current_exchange_type
        resolve_config(:exchange_type, :@exchange_type) || 'direct'
      end

      # @return [String] Nombre del recurso (ruta base para la URL).
      def resource_name
        resolve_config(:resource_name, :@resource_name) || name.demodulize.underscore.pluralize
      end

      # @return [String] Clave raíz para envolver los parámetros JSON.
      def param_key
        resolve_config(:param_key, :@param_key) || model_name.element
      end

      # Registra un middleware personalizado para el cliente de este recurso.
      # @yield [conn] Bloque de configuración del stack.
      def client_middleware(&block)
        (@client_middleware_stack ||= []) << block
      end

      # Instancia un cliente configurado listo para usar.
      # @return [BugBunny::Client] Cliente con pool y middlewares aplicados.
      # @raise [BugBunny::Error] Si falta el connection_pool.
      def bug_bunny_client
        pool = connection_pool
        raise BugBunny::Error, "Connection pool missing for #{name}" unless pool

        BugBunny::Client.new(pool: pool) do |conn|
          stack = resolve_middleware_stack
          stack.each { |block| block.call(conn) }
        end
      end

      # Ejecuta un bloque bajo un contexto de configuración temporal.
      # Útil para Sharding o Multi-Tenancy.
      #
      # @param exchange [String] Exchange temporal.
      # @param routing_key [String] Routing Key temporal.
      # @param exchange_type [String] Tipo de exchange.
      # @param pool [ConnectionPool] Pool de conexiones alternativo.
      # @yield Bloque a ejecutar en el contexto.
      # @return [Object, BugBunny::Resource::ScopeProxy] Resultado del bloque o Proxy.
      def with(exchange: nil, routing_key: nil, exchange_type: nil, pool: nil)
        ctx = { exchange: exchange, routing_key: routing_key,
                exchange_type: exchange_type, pool: pool }.compact

        run_in_scope(ctx) { block_given? ? yield : nil }
      end

      # Calcula la Routing Key final.
      # @param _id [Object] ID opcional del recurso (para sharding).
      # @return [String] La routing key.
      def calculate_routing_key(_id = nil)
        thread_config(:routing_key) || resolve_config(:routing_key, :@routing_key) || resource_name
      end

      private

      def resolve_middleware_stack
        stack = []
        target = self
        while target <= BugBunny::Resource
          middlewares = target.instance_variable_get(:@client_middleware_stack)
          stack.unshift(*middlewares) if middlewares
          target = target.superclass
        end
        stack
      end

      def run_in_scope(context)
        keys, old_values = push_thread_context(context)
        return BugBunny::Resource::ScopeProxy.new(self, keys, old_values) unless block_given?

        begin
          yield
        ensure
          pop_thread_context(keys, old_values)
        end
      end

      def push_thread_context(context)
        keys = context.keys.each_with_object({}) { |k, h| h[k] = "bb_#{object_id}_#{k}" }
        old_values = keys.transform_values { |v| Thread.current[v] }
        keys.each { |k, v| Thread.current[v] = context[k] }
        [keys, old_values]
      end

      def pop_thread_context(keys, old_values)
        keys.each { |k, v| Thread.current[v] = old_values[k] }
      end
    end
  end
end
