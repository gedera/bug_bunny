# lib/bug_bunny/resource.rb
module BugBunny
  # Clase base para modelos que interactúan con microservicios remotos vía RabbitMQ.
  # Implementa una interfaz similar a Active Record.
  #
  # @example
  #   class User < BugBunny::Resource
  #     attribute :name, :string
  #     validates :name, presence: true
  #   end
  class Resource
    include ActiveModel::API
    include ActiveModel::Attributes
    include ActiveModel::Dirty
    include ActiveModel::Validations

    class << self
      attr_accessor :resource_path
      attr_writer :resource_name

      def resource_name
        @resource_name ||= name.demodulize.underscore
      end

      def inherited(subclass)
        super

        subclass.resource_path = resource_path if resource_path.present?
      end
    end

    class ExchangeScope
      attr_reader :exchange_name, :routing_key, :klass

      def initialize(klass, exchange_name, routing_key = nil)
        @klass = klass
        @exchange_name = exchange_name
        @routing_key = routing_key
      end

      def method_missing(method_name, *args, **kwargs, &block)
        if @klass.respond_to?(method_name, true)
          kwargs[:exchange] = @exchange_name
          kwargs[:routing_key] = @routing_key if @routing_key.present?
          @klass.execute(method_name.to_sym, *args, **kwargs, &block)
        else
          super
        end
      end

      def respond_to_missing?(method_name, include_private = false)
        @klass.respond_to?(method_name, true) || super
      end
    end

    attribute :persisted, :boolean, default: false
    attribute :current_exchange
    attribute :current_routing_key

    def initialize(attributes = {})
      attributes.each do |key, value|
        attribute_name = key.to_sym
        type = guess_type(value)

        next if self.class.attribute_names.include?(attribute_name.to_s)

        self.class.attribute attribute_name, type if type.present?
      end

      super(attributes)

      self.current_exchange = self.class.current_exchange
      self.current_routing_key = self.class.current_routing_key

      @previously_persisted = persisted
      clear_changes_information if persisted?
    end

    def assign_attributes(attrs)
      return if attrs.blank?

      attrs.each do |key, val|
        setter_method = "#{key}="

        next unless respond_to?(setter_method)

        send(setter_method, val)
      end
    end

    def guess_type(value)
      case value
      when Integer then :integer
      when Float then :float
      when Date then :date
      when Time, DateTime then :datetime
      when TrueClass, FalseClass then :boolean
      when String then :string
      end
    end

    def persisted?
      persisted
    end

    def update(attrs_changes)
      assign_attributes(attrs_changes)
      save
    end

    def changes_to_send
      attrs = {}

      changes.each do |attribute, values|
        next if attribute.to_sym.in?(%i[current_exchange current_routing_key])

        attrs[attribute] = values[1]
      end

      attrs
    end

    def save
      return self if persisted? && changes.empty?

      obj = if persisted?
              self.class.publisher.send(self.class.update_action.to_sym, id: id, exchange: current_exchange, routing_key: current_routing_key, message: changes_to_send)
            else
              self.class.publisher.send(self.class.create_action.to_sym, exchange: current_exchange, routing_key: current_routing_key, message: changes_to_send)
            end

      assign_attributes(obj) # refresco el objeto
      self.persisted = true
      @previously_persisted = true
      clear_changes_information
      true
    rescue BugBunny::Error::UnprocessableEntity => e
      load_remote_rabbit_errors(e.message)
      false
    end

    def destroy
      return self unless persisted?

      # Llamada al PUBLISHER sin el argumento 'box'
      self.class.publisher.send(destroy_action.to_sym, exchange: current_exchange, routing_key: current_routing_key, id: id)

      self.persisted = false
      true
    rescue BugBunny::Error::UnprocessableEntity => e
      load_remote_rabbit_errors(e.message)
      false
    end

    def inspect
      # Creamos una lista bonita de atributos: "id: 123, name: 'Pepe'"
      inspection = attributes.map do |name, value|
        "#{name}: #{value.nil? ? 'nil' : value.inspect}"
      end.join(", ")

      "#<#{self.class.name} #{inspection}>"
    end

    def self.for_exchange(exchange_name, routing_key = nil)
      raise ArgumentError, 'Exchange name must be specified.' if exchange_name.blank?

      ExchangeScope.new(self, exchange_name, routing_key)
    end

    def self.execute(name, *args, **kwargs, &block)
      original_exchange = Thread.current[:bugbunny_current_exchange]
      Thread.current[:bugbunny_current_exchange] = kwargs[:exchange]
      original_routing_key = Thread.current[:bugbunny_current_routing_key]
      Thread.current[:bugbunny_current_routing_key] = kwargs[:routing_key]
      begin
        kwargs.delete(:exchange)
        kwargs.delete(:routing_key)
        send(name, *args, **kwargs, &block)
      ensure
        Thread.current[:bugbunny_current_exchange] = original_exchange
        Thread.current[:bugbunny_current_routing_key] = original_routing_key
      end
    end

    def self.current_exchange
      Thread.current[:bugbunny_current_exchange]
    end

    def self.current_routing_key
      Thread.current[:bugbunny_current_routing_key]
    end

    def self.all
      where
    end

    def self.where(query = {})
      body = publisher.send(index_action.to_sym, exchange: current_exchange, routing_key: current_routing_key, message: query)
      instances = []

      body.each do |obj|
        instance = new
        instance.assign_attributes(obj.merge(persisted: true))
        instances << instance
      end

      instances
    end

    def self.find(id)
      obj = publisher.send(show_action.to_sym, exchange: current_exchange, routing_key: current_routing_key, id: id)
      return if obj.blank?

      instance = new
      instance.assign_attributes(obj.merge(persisted: true))
      instance
    end

    def self.create(payload)
      instance = new(payload)
      instance.save
      instance
    end

    def self.index_action
      :index
    end

    def self.show_action
      :show
    end

    def self.create_action
      :create
    end

    def self.update_action
      :update
    end

    def self.destroy_action
      :destroy
    end

    def self.publisher
      @publisher ||= if resource_path.end_with?('/')
                       [resource_path, resource_name].join('').camelize.constantize
                     else
                       [resource_path, resource_name].join('/').camelize.constantize
                     end
    end

    def load_remote_rabbit_errors(errors_hash)
      return if errors_hash.blank?

      errors_hash.each do |attribute, errors|
        # Manejo defensivo por si 'errors' no es un array
        Array.wrap(errors).each do |error|
          if error.is_a?(Hash)
            # Formato complejo: { "error": "is invalid", "code": "123" }
            self.errors.add(attribute, error['error'], **error.except('error').symbolize_keys)
          else
            # Formato simple: "is invalid"
            self.errors.add(attribute, error)
          end
        end
      end
    end

    private_class_method :all, :where, :find, :create
  end
end
