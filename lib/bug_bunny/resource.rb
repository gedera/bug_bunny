require 'active_model'
require 'active_support/core_ext/string/inflections'

module BugBunny
  class Resource
    include ActiveModel::API
    include ActiveModel::Attributes
    include ActiveModel::Dirty
    include ActiveModel::Validations

    class << self
      # Setters
      attr_writer :connection_pool, :exchange, :exchange_type, :routing_key_prefix, :resource_name

      def resolve_config(key, instance_var)
        # 1. Buscar override temporal en el Thread (Contexto .with)
        thread_key = "bb_#{object_id}_#{key}"
        return Thread.current[thread_key] if Thread.current.key?(thread_key)

        # 2. Obtener valor base
        value = instance_variable_get(instance_var)

        # 3. Si es un Proc/Lambda, evaluarlo. Si no, devolver valor.
        value.respond_to?(:call) ? value.call : value
      end

      def connection_pool
        resolve_config(:pool, :@connection_pool)
      end

      def current_exchange
        resolve_config(:exchange, :@exchange) || raise(ArgumentError, "Exchange not defined for #{name}")
      end

      def current_exchange_type
        resolve_config(:exchange_type, :@exchange_type) || 'direct'
      end

      def current_routing_key_prefix
        resolve_config(:prefix, :@routing_key_prefix)
      end

      def resource_name
        @resource_name ||= name.demodulize.underscore
      end

      def bug_bunny_client
        pool = connection_pool
        raise BugBunny::Error, "connection_pool not configured for #{name}" unless pool
        # Nota: Podríamos cachear el cliente si el pool es el mismo,
        # pero para soportar pool dinámico, instanciamos ligero.
        BugBunny::Client.new(pool: pool)
      end

      # === MÉTODO .WITH (Fluent Interface) ===
      # Permite cambiar configuración solo para un bloque o cadena
      # Uso: TestUser.with(exchange: 'otro').find(1)
      def with(exchange: nil, routing_key: nil, exchange_type: nil, pool: nil)
        # Guardamos estado anterior
        keys = {
          exchange: "bb_#{object_id}_exchange",
          exchange_type: "bb_#{object_id}_exchange_type",
          pool: "bb_#{object_id}_pool",
          routing_key: "bb_#{object_id}_routing_key" # Este es especial para override total
        }

        old_values = {}
        keys.each { |k, v| old_values[k] = Thread.current[v] }

        # Seteamos nuevos valores
        Thread.current[keys[:exchange]] = exchange if exchange
        Thread.current[keys[:exchange_type]] = exchange_type if exchange_type
        Thread.current[keys[:pool]] = pool if pool
        Thread.current[keys[:routing_key]] = routing_key if routing_key

        # Retornamos self para encadenar (Chainable) o ejecutamos bloque
        if block_given?
          begin
            yield
          ensure
            # Restaurar
            keys.each { |k, v| Thread.current[v] = old_values[k] }
          end
        else
          # Modo Proxy para encadenar: TestUser.with(...).find(...)
          # Creamos un proxy que limpie el thread después de la llamada
          ScopeProxy.new(self, keys, old_values)
        end
      end

      # Proxy para limpiar el thread automáticamente después de una llamada encadenada
      class ScopeProxy < BasicObject
        def initialize(target, keys, old_values)
          @target = target
          @keys = keys
          @old_values = old_values
        end

        def method_missing(method, *args, &block)
          @target.public_send(method, *args, &block)
        ensure
          # Limpieza automática post-ejecución
          @keys.each { |k, v| ::Thread.current[v] = @old_values[k] }
        end
      end

      # === LÓGICA DE RUTEO ===

      def calculate_routing_key(action)
        # Override manual directo (via .with(routing_key: ...))
        manual_rk = Thread.current["bb_#{object_id}_routing_key"]
        return manual_rk if manual_rk

        prefix = current_routing_key_prefix
        return action.to_s unless prefix

        "#{prefix}.#{action}"
      end

      def index_action; :index; end
      def show_action; :show; end
      def create_action; :create; end
      def update_action; :update; end
      def destroy_action; :destroy; end

      def find(id)
        url_path = "#{resource_name}/#{show_action}"
        rk = calculate_routing_key(show_action)

        response = bug_bunny_client.request(url_path, exchange: current_exchange, exchange_type: current_exchange_type) do |req|
           req.routing_key = rk
           req.headers[:id] = id
        end

        return nil if response.nil? || response['status'] == 404

        attributes = response['body']
        return nil unless attributes.is_a?(Hash)

        instance = new
        instance.assign_attributes(attributes)
        instance.persisted = true
        instance.send(:clear_changes_information)
        instance
      end

      def create(payload)
        instance = new(payload)
        instance.save
        instance
      end
    end

    # Instancia
    def current_exchange; self.class.current_exchange; end
    def current_exchange_type; self.class.current_exchange_type; end
    def calculate_routing_key(action); self.class.calculate_routing_key(action); end

    # IMPORTANTE: El cliente de instancia también debe ser dinámico
    def bug_bunny_client; self.class.bug_bunny_client; end

    attribute :persisted, :boolean, default: false

    def initialize(attributes = {})
      super(attributes)
      @previously_persisted = persisted
    end

    def persisted?
      persisted
    end

    def assign_attributes(new_attributes)
      return if new_attributes.nil?
      new_attributes.each do |k, v|
        setter = "#{k}="
        public_send(setter, v) if respond_to?(setter)
      end
    end

    def changes_to_send
      attrs = {}
      changes.each do |attr, vals|
        next if attr.to_sym == :persisted
        attrs[attr] = vals[1]
      end
      attrs
    end

    def save
      return self if persisted? && changes.empty?

      action_verb = persisted? ? self.class.update_action : self.class.create_action
      url_path = "#{self.class.resource_name}/#{action_verb}"
      rk = calculate_routing_key(action_verb)

      response = bug_bunny_client.request(url_path, exchange: current_exchange, exchange_type: current_exchange_type) do |req|
        req.routing_key = rk
        req.headers[:id] = id if persisted?
        req.body = changes_to_send
      end

      if response['status'] == 422
        raise BugBunny::UnprocessableEntity.new(response['body']['errors'] || response['body'])
      elsif response['status'] >= 500
        raise BugBunny::InternalServerError, "Server Error: #{response['status']}"
      elsif response['status'] >= 400
        raise BugBunny::ClientError, "Request Failed: #{response['status']}"
      end

      assign_attributes(response['body'])

      self.persisted = true
      @previously_persisted = true
      clear_changes_information
      true
    rescue BugBunny::UnprocessableEntity => e
      load_remote_rabbit_errors(e.error_messages)
      false
    end

    def destroy
      return self unless persisted?

      url_path = "#{self.class.resource_name}/#{self.class.destroy_action}"
      rk = calculate_routing_key(self.class.destroy_action)

      response = bug_bunny_client.request(url_path, exchange: current_exchange, exchange_type: current_exchange_type) do |req|
        req.routing_key = rk
        req.headers[:id] = id
      end

      if response['status'] >= 500
         raise BugBunny::InternalServerError
      elsif response['status'] >= 400
         raise BugBunny::ClientError
      end

      self.persisted = false
      true
    end

    def load_remote_rabbit_errors(errors_hash)
      return if errors_hash.nil?
      if errors_hash.is_a?(String)
        errors.add(:base, errors_hash)
      else
        errors_hash.each do |attribute, msgs|
          Array(msgs).each { |msg| errors.add(attribute, msg) }
        end
      end
    end
  end
end
