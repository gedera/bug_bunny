require 'active_model'
require 'active_support/core_ext/string/inflections'

module BugBunny
  class Resource
    include ActiveModel::API
    include ActiveModel::Attributes
    include ActiveModel::Dirty
    include ActiveModel::Validations

    class << self
      attr_accessor :resource_path
      attr_writer :resource_name
      attr_accessor :connection_pool

      def resource_name
        @resource_name ||= name.demodulize.underscore
      end

      # Singleton del Cliente (Lazy Load)
      def bug_bunny_client
        raise BugBunny::Error, "connection_pool not configured for #{name}" unless connection_pool
        @bug_bunny_client ||= BugBunny::Client.new(pool: connection_pool)
      end

      # Scope Chaining
      def for_exchange(exchange_name, routing_key = nil)
        raise ArgumentError, 'Exchange name required.' if exchange_name.nil? || exchange_name.empty?
        ExchangeScope.new(self, exchange_name, routing_key)
      end

      # Helper para scope seguro con Threads
      def with_scope(exchange, routing_key)
        old_x = Thread.current[:bb_exchange]
        old_rk = Thread.current[:bb_routing_key]
        Thread.current[:bb_exchange] = exchange
        Thread.current[:bb_routing_key] = routing_key
        yield
      ensure
        Thread.current[:bb_exchange] = old_x
        Thread.current[:bb_routing_key] = old_rk
      end

      def current_exchange
        Thread.current[:bb_exchange]
      end

      def current_routing_key
        Thread.current[:bb_routing_key]
      end

      # Acciones RESTful
      def index_action; :index; end
      def show_action; :show; end
      def create_action; :create; end
      def update_action; :update; end
      def destroy_action; :destroy; end

      # Find
      def find(id)
        url_path = "#{resource_name}/#{show_action}"
        obj = bug_bunny_client.request(url_path, exchange: current_exchange) do |req|
           req.routing_key = current_routing_key
           req.headers[:id] = id
        end
        return nil if obj.nil? || (obj.respond_to?(:empty?) && obj.empty?)

        instance = new
        instance.assign_attributes(obj.merge(persisted: true))
        instance
      end

      # Create
      def create(payload)
        instance = new(payload)
        instance.save
        instance
      end
    end

    class ExchangeScope
      def initialize(klass, exchange_name, routing_key)
        @klass = klass
        @exchange_name = exchange_name
        @routing_key = routing_key
      end

      def method_missing(method_name, *args, **kwargs, &block)
        if @klass.respond_to?(method_name, true)
           @klass.with_scope(@exchange_name, @routing_key) do
             @klass.send(method_name, *args, **kwargs, &block)
           end
        else
          super
        end
      end
    end

    attribute :persisted, :boolean, default: false
    attribute :current_exchange
    attribute :current_routing_key

    def initialize(attributes = {})
      super(attributes)
      self.current_exchange = self.class.current_exchange
      self.current_routing_key = self.class.current_routing_key
      @previously_persisted = persisted
      clear_changes_information if persisted?
    end

    def assign_attributes(attrs)
      return if attrs.nil?

      attrs.each do |key, val|
        setter = "#{key}="
        send(setter, val) if respond_to?(setter)
      end
    end

    def persisted?
      persisted
    end

    def changes_to_send
      attrs = {}
      changes.each do |attr, vals|
        next if attr.to_sym.in?(%i[current_exchange current_routing_key persisted])

        attrs[attr] = vals[1]
      end
      attrs
    end

    def save
      return self if persisted? && changes.empty?

      action_verb = persisted? ? self.class.update_action : self.class.create_action
      url_path = "#{self.class.resource_name}/#{action_verb}"

      obj = self.class.bug_bunny_client.request(url_path, exchange: current_exchange) do |req|
        req.routing_key = current_routing_key
        req.headers[:id] = id if persisted?
        req.body = changes_to_send
      end

      assign_attributes(obj)
      self.persisted = true
      @previously_persisted = true
      clear_changes_information
      true
    rescue BugBunny::Error::UnprocessableEntity => e
      load_remote_rabbit_errors(e.error_messages)
      false
    end

    def destroy
      return self unless persisted?

      url_path = "#{self.class.resource_name}/#{self.class.destroy_action}"

      self.class.bug_bunny_client.request(url_path, exchange: current_exchange) do |req|
        req.routing_key = current_routing_key
        req.headers[:id] = id
      end

      self.persisted = false
      true
    rescue BugBunny::Error::UnprocessableEntity => e
      load_remote_rabbit_errors(e.error_messages)
      false
    end

    def load_remote_rabbit_errors(errors_hash)
      return if errors_hash.nil?

      errors_hash.each do |attribute, errors|
        Array(errors).each do |error|
          self.errors.add(attribute, error)
        end
      end
    end
  end
end
