# frozen_string_literal: true

require 'active_model'
require 'active_support/core_ext/string/inflections'
require 'uri'
require 'set' # Necesario para el tracking manual
require 'rack/utils'

module BugBunny
  # Clase base para modelos remotos que implementan **Active Record over AMQP (RESTful)**.
  #
  # Soporta un esquema híbrido de datos:
  # 1. **Atributos Tipados:** Definidos con `attribute :name, :type`.
  # 2. **Atributos Dinámicos:** Asignados al vuelo sin definición previa.
  #
  # Implementa un sistema de "Dirty Tracking" híbrido para detectar cambios
  # tanto en atributos tipados (via ActiveModel) como dinámicos (via Set manual).
  #
  # @author Gabriel
  # @since 3.0.6
  class Resource
    include ActiveModel::API
    include ActiveModel::Attributes
    include ActiveModel::Dirty
    include ActiveModel::Validations
    extend ActiveModel::Callbacks

    define_model_callbacks :save, :create, :update, :destroy

    attr_reader :remote_attributes
    attr_accessor :persisted
    attr_accessor :routing_key, :exchange, :exchange_type

    class << self
      attr_writer :connection_pool, :exchange, :exchange_type, :resource_name, :routing_key, :param_key

      def thread_config(key); Thread.current["bb_#{object_id}_#{key}"]; end

      def resolve_config(key, instance_var)
        val = thread_config(key)
        return val if val
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

      def param_key
        resolve_config(:param_key, :@param_key) || model_name.element
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

      def calculate_routing_key(id = nil)
        manual_rk = thread_config(:routing_key)
        return manual_rk if manual_rk
        static_rk = resolve_config(:routing_key, :@routing_key)
        return static_rk if static_rk.present?
        resource_name
      end

      # @!group Acciones CRUD RESTful
      def where(filters = {})
        rk = calculate_routing_key
        path = resource_name
        path += "?#{Rack::Utils.build_nested_query(filters)}" if filters.present?
        response = bug_bunny_client.request(path, method: :get, exchange: current_exchange, exchange_type: current_exchange_type, routing_key: rk)
        return [] unless response['body'].is_a?(Array)
        response['body'].map do |attrs|
          inst = new(attrs)
          inst.persisted = true
          inst.send(:clear_changes_information)
          inst
        end
      end

      def all; where({}); end

      def find(id)
        rk = calculate_routing_key(id)
        path = "#{resource_name}/#{id}"
        response = bug_bunny_client.request(path, method: :get, exchange: current_exchange, exchange_type: current_exchange_type, routing_key: rk)
        return nil if response.nil? || response['status'] == 404
        return nil unless response['body'].is_a?(Hash)
        instance = new(response['body'])
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

    # @!group Instancia

    def initialize(attributes = {})
      @remote_attributes = {}.with_indifferent_access
      @dynamic_changes = Set.new # Rastreo manual para atributos dinámicos
      @persisted = false
      @routing_key = self.class.thread_config(:routing_key)
      @exchange = self.class.thread_config(:exchange)
      @exchange_type = self.class.thread_config(:exchange_type)

      super()
      assign_attributes(attributes)
    end

    # Limpia tanto el rastreo de ActiveModel como nuestro rastreo dinámico.
    def clear_changes_information
      super
      @dynamic_changes.clear
    end

    def attributes_for_serialization
      @remote_attributes.merge(attributes)
    end

    def calculate_routing_key(id=nil); @routing_key || self.class.calculate_routing_key(id); end
    def current_exchange; @exchange || self.class.current_exchange; end
    def current_exchange_type; @exchange_type || self.class.current_exchange_type; end
    def bug_bunny_client; self.class.bug_bunny_client; end
    def persisted?; !!@persisted; end

    def assign_attributes(new_attributes)
      return if new_attributes.nil?
      new_attributes.each { |k, v| public_send("#{k}=", v) }
    end

    def update(attributes)
      assign_attributes(attributes)
      save
    end

    # Retorna el hash combinado de cambios (Tipados + Dinámicos).
    def changes_to_send
      # 1. Cambios de ActiveModel (Tipados)
      # changes returns { 'attr' => [old, new] } -> nos quedamos con new
      payload = changes.transform_values(&:last)

      # 2. Cambios Dinámicos (Manuales)
      @dynamic_changes.each do |key|
        payload[key] = @remote_attributes[key]
      end

      return payload unless payload.empty?

      # Fallback: Si no hay cambios detectados, enviamos todo (útil para create)
      attributes_for_serialization.except('id', 'ID', 'Id', '_id')
    end

    # Intercepta asignaciones dinámicas y las marca como sucias.
    def method_missing(method_name, *args, &block)
      attribute_name = method_name.to_s
      if attribute_name.end_with?('=')
        key = attribute_name.chop
        val = args.first

        # Dirty Tracking Manual
        # Si el valor cambia, lo marcamos en nuestro Set
        if @remote_attributes[key] != val
          @dynamic_changes << key
        end

        @remote_attributes[key] = val
      else
        @remote_attributes.key?(attribute_name) ? @remote_attributes[attribute_name] : super
      end
    end

    def respond_to_missing?(method_name, include_private = false)
      @remote_attributes.key?(method_name.to_s.sub(/=$/, '')) || super
    end

    def id
      attributes['id'] || @remote_attributes['id'] || @remote_attributes['ID'] || @remote_attributes['Id'] || @remote_attributes['_id']
    end

    def id=(value)
      if self.class.attribute_names.include?('id')
        super(value)
      else
        @remote_attributes['id'] = value
      end
    end

    def read_attribute_for_validation(attr)
      attr_s = attr.to_s
      self.class.attribute_names.include?(attr_s) ? attribute(attr_s) : @remote_attributes[attr_s]
    end

    # @!group Persistencia

    def save
      return false unless valid?

      run_callbacks(:save) do
        is_new = !persisted?
        rk = calculate_routing_key(id)
        flat_payload = changes_to_send
        key = self.class.param_key
        wrapped_payload = { key => flat_payload }

        path = is_new ? self.class.resource_name : "#{self.class.resource_name}/#{id}"
        method = is_new ? :post : :put

        response = bug_bunny_client.request(
          path,
          method: method,
          exchange: current_exchange,
          exchange_type: current_exchange_type,
          routing_key: rk,
          body: wrapped_payload
        )

        handle_save_response(response)
      end
    rescue BugBunny::UnprocessableEntity => e
      load_remote_rabbit_errors(e.error_messages)
      false
    end

    def destroy
      return false unless persisted?
      run_callbacks(:destroy) do
        path = "#{self.class.resource_name}/#{id}"
        rk = calculate_routing_key(id)
        bug_bunny_client.request(path, method: :delete, exchange: current_exchange, exchange_type: current_exchange_type, routing_key: rk)
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
