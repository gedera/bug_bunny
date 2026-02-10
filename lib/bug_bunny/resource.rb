# lib/bug_bunny/resource.rb
require 'active_model'
require 'active_support/core_ext/string/inflections'
require 'uri'

module BugBunny
  # Clase base para modelos remotos (Active Record over AMQP RESTful).
  #
  # Mapea operaciones CRUD de objetos Ruby a verbos HTTP sobre RabbitMQ.
  class Resource
    include ActiveModel::API
    include ActiveModel::Dirty
    include ActiveModel::Validations
    extend ActiveModel::Callbacks

    define_model_callbacks :save, :create, :update, :destroy

    attr_reader :remote_attributes
    attr_accessor :persisted

    class << self
      # ... (Configuración igual que antes: resolve_config, connection_pool, etc) ...
      attr_writer :connection_pool, :exchange, :exchange_type, :resource_name, :routing_key

      def resolve_config(key, instance_var)
        thread_key = "bb_#{object_id}_#{key}"
        return Thread.current[thread_key] if Thread.current.key?(thread_key)
        target = self
        while target <= BugBunny::Resource
          value = target.instance_variable_get(instance_var)
          return value.respond_to?(:call) ? value.call : value unless value.nil?
          target = target.superclass
        end
        nil
      end

      def connection_pool; resolve_config(:pool, :@connection_pool); end
      def current_exchange; resolve_config(:exchange, :@exchange) || raise(ArgumentError, "Exchange not defined"); end
      def current_exchange_type; resolve_config(:exchange_type, :@exchange_type) || 'direct'; end

      def resource_name
        resolve_config(:resource_name, :@resource_name) || name.demodulize.underscore.pluralize
      end

      def client_middleware(&block)
        @client_middleware_stack ||= []
        @client_middleware_stack << block
      end

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

      def bug_bunny_client
        pool = connection_pool
        raise BugBunny::Error, "Connection pool missing for #{name}" unless pool

        BugBunny::Client.new(pool: pool) do |conn|
          resolve_middleware_stack.each { |block| block.call(conn) }
        end
      end

      def with(exchange: nil, routing_key: nil, exchange_type: nil, pool: nil)
        keys = { exchange: "bb_#{object_id}_exchange", exchange_type: "bb_#{object_id}_exchange_type", pool: "bb_#{object_id}_pool", routing_key: "bb_#{object_id}_routing_key" }
        old_values = {}
        keys.each { |k, v| old_values[k] = Thread.current[v] }
        Thread.current[keys[:exchange]] = exchange if exchange
        Thread.current[keys[:exchange_type]] = exchange_type if exchange_type
        Thread.current[keys[:pool]] = pool if pool
        Thread.current[keys[:routing_key]] = routing_key if routing_key

        if block_given?
          begin; yield; ensure; keys.each { |k, v| Thread.current[v] = old_values[k] }; end
        else
          ScopeProxy.new(self, keys, old_values)
        end
      end

      class ScopeProxy < BasicObject
        def initialize(target, keys, old_values); @target = target; @keys = keys; @old_values = old_values; end
        def method_missing(method, *args, &block); @target.public_send(method, *args, &block); ensure; @keys.each { |k, v| ::Thread.current[v] = @old_values[k] }; end
      end

      # Calcula la Routing Key.
      # Si hay routing_key fija, la usa. Si no, usa el resource_name como key.
      # @note En REST, la routing key suele ser el nombre del recurso (ej: 'users').
      def calculate_routing_key(id = nil)
        manual_rk = Thread.current["bb_#{object_id}_routing_key"]
        return manual_rk if manual_rk

        static_rk = resolve_config(:routing_key, :@routing_key)
        return static_rk if static_rk.present?

        # Por defecto la routing key es el nombre del recurso (ej: 'users')
        # Esto asume un Topic Exchange donde se escucha 'users' o 'users.*'
        resource_name
      end

      # @!group Acciones CRUD RESTful

      # GET resource?query
      def where(filters = {})
        rk = calculate_routing_key
        path = resource_name
        path += "?#{URI.encode_www_form(filters)}" if filters.present?

        response = bug_bunny_client.get(path, exchange: current_exchange, exchange_type: current_exchange_type, routing_key: rk)

        return [] unless response['body'].is_a?(Array)
        response['body'].map do |attrs|
          inst = new(attrs)
          inst.persisted = true
          inst.send(:clear_changes_information)
          inst
        end
      end

      def all; where({}); end

      # GET resource/id
      def find(id)
        rk = calculate_routing_key(id)
        path = "#{resource_name}/#{id}"

        response = bug_bunny_client.get(path, exchange: current_exchange, exchange_type: current_exchange_type, routing_key: rk)

        return nil if response.nil? || response['status'] == 404

        attributes = response['body']
        return nil unless attributes.is_a?(Hash)

        instance = new(attributes)
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

    # @!group Instancia (Sin cambios mayores, solo en save/destroy)

    def current_exchange; self.class.current_exchange; end
    def current_exchange_type; self.class.current_exchange_type; end
    def calculate_routing_key(id=nil); self.class.calculate_routing_key(id); end
    def bug_bunny_client; self.class.bug_bunny_client; end

    def initialize(attributes = {})
      @remote_attributes = {}.with_indifferent_access
      @persisted = false
      assign_attributes(attributes)
      super()
    end

    def persisted?; !!@persisted; end

    def assign_attributes(new_attributes)
      return if new_attributes.nil?

      new_attributes.each { |k, v| public_send("#{k}=", v) }
    end

    def update(attributes)
      assign_attributes(attributes)
      save
    end

    def changes_to_send
      return changes.transform_values(&:last) unless changes.empty?
      @remote_attributes.except('id', 'ID', 'Id', '_id')
    end

    def method_missing(method_name, *args, &block)
      attribute_name = method_name.to_s
      if attribute_name.end_with?('=')
        key = attribute_name.chop
        val = args.first
        attribute_will_change!(key) unless @remote_attributes[key] == val
        @remote_attributes[key] = val
      else
        @remote_attributes.key?(attribute_name) ? @remote_attributes[attribute_name] : super
      end
    end

    def respond_to_missing?(method_name, include_private = false)
      @remote_attributes.key?(method_name.to_s.sub(/=$/, '')) || super
    end

    def id
      @remote_attributes['id'] || @remote_attributes['ID'] || @remote_attributes['Id'] || @remote_attributes['_id']
    end

    def id=(value)
      @remote_attributes['id'] = value
    end

    def read_attribute_for_validation(attr)
      @remote_attributes[attr.to_s]
    end

    # @!group Persistencia RESTful

    def save
      return false unless valid?

      run_callbacks(:save) do
        is_new = !persisted?
        rk = calculate_routing_key(id)

        # Mapeo a verbos HTTP
        if is_new
          # POST resource
          path = self.class.resource_name
          response = bug_bunny_client.post(path, exchange: current_exchange, exchange_type: current_exchange_type, routing_key: rk, body: changes_to_send)
        else
          # PUT resource/id
          path = "#{self.class.resource_name}/#{id}"
          response = bug_bunny_client.put(path, exchange: current_exchange, exchange_type: current_exchange_type, routing_key: rk, body: changes_to_send)
        end

        handle_save_response(response)
      end
    rescue BugBunny::UnprocessableEntity => e
      load_remote_rabbit_errors(e.error_messages)
      false
    end

    def destroy
      return false unless persisted?

      run_callbacks(:destroy) do
        # DELETE resource/id
        path = "#{self.class.resource_name}/#{id}"
        rk = calculate_routing_key(id)

        bug_bunny_client.delete(path, exchange: current_exchange, exchange_type: current_exchange_type, routing_key: rk)

        self.persisted = false
      end
      true
    rescue BugBunny::ServerError, BugBunny::ClientError
      false
    end

    private

    def handle_save_response(response)
      if response['status'] == 422
        raise BugBunny::UnprocessableEntity.new(response['body']['errors'] || response['body'])
      elsif response['status'] >= 500
        raise BugBunny::InternalServerError
      elsif response['status'] >= 400
        raise BugBunny::ClientError
      end

      assign_attributes(response['body'])
      self.persisted = true
      clear_changes_information
      true
    end

    def load_remote_rabbit_errors(errors_hash)
      return if errors_hash.nil?

      if errors_hash.is_a?(String)
        errors.add(:base, errors_hash)
      else
        errors_hash.each { |attr, msg| Array(msg).each { |m| errors.add(attr, m) } }
      end
    end
  end
end
