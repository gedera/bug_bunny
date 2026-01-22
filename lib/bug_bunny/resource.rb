# lib/bug_bunny/resource.rb
require 'active_model'
require 'active_support/core_ext/string/inflections'
require 'uri'

module BugBunny
  # Clase base para modelos remotos que implementan el patrón Active Record sobre AMQP.
  #
  # Esta clase transforma operaciones CRUD estándar en peticiones RPC (Remote Procedure Call)
  # siguiendo una semántica RESTful. Utiliza el header `type` del mensaje AMQP para simular
  # una URL (path + query string), permitiendo enrutamiento complejo en el consumidor.
  #
  # @example Definición de un modelo
  #   class User < BugBunny::Resource
  #     self.exchange = 'users.topic'
  #     self.exchange_type = 'topic'
  #     self.routing_key_prefix = 'users'
  #
  #     attribute :id, :integer
  #     attribute :name, :string
  #   end
  #
  # @example Consultas
  #   User.find(1)                        # type: "users/show/1"
  #   User.where(active: true, role: 'x') # type: "users/index?active=true&role=x"
  class Resource
    include ActiveModel::API
    include ActiveModel::Attributes
    include ActiveModel::Dirty
    include ActiveModel::Validations
    extend ActiveModel::Callbacks

    define_model_callbacks :save, :create, :update, :destroy

    class << self
      # @!group Configuración
      attr_writer :connection_pool, :exchange, :exchange_type, :routing_key_prefix, :resource_name

      # Resuelve la configuración buscando en una jerarquía de prioridades (Thread-local > Clase).
      # @api private
      def resolve_config(key, instance_var)
        thread_key = "bb_#{object_id}_#{key}"
        return Thread.current[thread_key] if Thread.current.key?(thread_key)
        value = instance_variable_get(instance_var)
        value.respond_to?(:call) ? value.call : value
      end

      def connection_pool
        resolve_config(:pool, :@connection_pool)
      end

      def current_exchange
        resolve_config(:exchange, :@exchange) || raise(ArgumentError, "Exchange not defined")
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

      # Instancia el cliente RPC utilizando el pool de conexiones configurado.
      # @return [BugBunny::Client]
      def bug_bunny_client
        pool = connection_pool
        raise BugBunny::Error, "Connection pool missing for #{name}" unless pool

        BugBunny::Client.new(pool: pool)
      end

      # Permite overrides temporales de configuración (Thread-safe).
      # @see BugBunny::Resource
      def with(exchange: nil, routing_key: nil, exchange_type: nil, pool: nil)
        keys = { exchange: "bb_#{object_id}_exchange", exchange_type: "bb_#{object_id}_exchange_type", pool: "bb_#{object_id}_pool", routing_key: "bb_#{object_id}_routing_key" }
        old_values = {}
        keys.each { |k, v| old_values[k] = Thread.current[v] }
        Thread.current[keys[:exchange]] = exchange if exchange
        Thread.current[keys[:exchange_type]] = exchange_type if exchange_type
        Thread.current[keys[:pool]] = pool if pool
        Thread.current[keys[:routing_key]] = routing_key if routing_key

        if block_given?
          begin
            yield
          ensure
            keys.each { |k, v| Thread.current[v] = old_values[k] }
          end
        else
          ScopeProxy.new(self, keys, old_values)
        end
      end

      # @api private
      class ScopeProxy < BasicObject
        def initialize(target, keys, old_values)
          @target = target
          @keys = keys
          @old_values = old_values
        end

        def method_missing(method, *args, &block)
          @target.public_send(method, *args, &block)
        ensure
          @keys.each { |k, v| ::Thread.current[v] = @old_values[k] }
        end
      end

      # Calcula la Routing Key de RabbitMQ.
      # @param action [Symbol] La acción (ej: :create).
      # @param id [String, nil] ID opcional para sufijar la key (ej: 'users.update.12').
      # @return [String]
      def calculate_routing_key(action, id = nil)
        manual_rk = Thread.current["bb_#{object_id}_routing_key"]
        return manual_rk if manual_rk

        prefix = current_routing_key_prefix
        key = prefix ? "#{prefix}.#{action}" : action.to_s
        key = "#{key}.#{id}" if id
        key
      end

      # @!group Acciones CRUD
      def index_action
        :index
      end

      def show_action
        :show
      end

      def create_action
        :create
      end

      def update_action
        :update
      end

      def destroy_action
        :destroy
      end

      # Recupera una colección de recursos aplicando filtros.
      #
      # Construye una URL en el header `type` incluyendo los filtros como Query Params.
      # Ej: `users/index?active=true&role=admin`
      #
      # @param filters [Hash] Filtros de búsqueda.
      # @return [Array<Resource>] Array de objetos hidratados.
      def where(filters = {})
        rk = calculate_routing_key(index_action)
        path = "#{resource_name}/#{index_action}"

        # Construcción de URL con Query String seguro
        if filters.present?
          query_string = URI.encode_www_form(filters)
          type_header = "#{path}?#{query_string}"
        else
          type_header = path
        end

        response = bug_bunny_client.request(type_header, exchange: current_exchange, exchange_type: current_exchange_type) do |req|
          req.routing_key = rk
          # El body viaja vacío, los filtros van en la "URL" (header type)
        end

        return [] unless response['body'].is_a?(Array)

        response['body'].map do |attrs|
          inst = new(attrs)
          inst.persisted = true
          inst.send(:clear_changes_information)
          inst
        end
      end

      # Recupera todos los registros (alias de where sin filtros).
      # @return [Array<Resource>]
      def all
        where
      end

      # Busca un recurso por su ID.
      #
      # Construye una URL RESTful: `resource/show/:id`.
      #
      # @param id [Integer, String] ID del recurso.
      # @return [Resource, nil] Objeto encontrado o nil si es 404.
      def find(id)
        rk = calculate_routing_key(show_action, id)
        # URL RESTful: users/show/12
        type_header = "#{resource_name}/#{show_action}/#{id}"

        response = bug_bunny_client.request(type_header, exchange: current_exchange, exchange_type: current_exchange_type) do |req|
           req.routing_key = rk
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

      # Crea un nuevo recurso.
      # @param payload [Hash] Atributos.
      # @return [Resource] Instancia creada.
      def create(payload)
        instance = new(payload)
        instance.save
        instance
      end
    end

    # @!group Instancia
    def current_exchange
      self.class.current_exchange
    end

    def current_exchange_type
      self.class.current_exchange_type
    end

    def calculate_routing_key(action, id=nil)
      self.class.calculate_routing_key(action, id)
    end

    def bug_bunny_client
      self.class.bug_bunny_client
    end

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

      super(new_attributes)
    end

    # Actualiza atributos y guarda.
    def update(attributes)
      assign_attributes(attributes)
      save
    end

    def changes_to_send
      changes.transform_values(&:last).except(:persisted)
    end

    # Guarda el registro (Create o Update).
    #
    # * Create: Genera URL `users/create`
    # * Update: Genera URL `users/update/12`
    #
    # @return [Boolean] true si éxito, false si error de validación.
    def save
      return false unless valid?

      run_callbacks(:save) do
        is_new = !persisted?
        action_verb = is_new ? self.class.create_action : self.class.update_action

        if is_new
          type_header = "#{self.class.resource_name}/#{action_verb}"
          rk = calculate_routing_key(action_verb)
        else
          type_header = "#{self.class.resource_name}/#{action_verb}/#{id}"
          rk = calculate_routing_key(action_verb, id)
        end

        response = bug_bunny_client.request(type_header, exchange: current_exchange, exchange_type: current_exchange_type) do |req|
          req.routing_key = rk
          req.body = changes_to_send # Solo atributos modificados
        end

        handle_save_response(response)
      end
    rescue BugBunny::UnprocessableEntity => e
      load_remote_rabbit_errors(e.error_messages)
      false
    end

    # Elimina el registro remoto.
    # Genera URL `users/destroy/12`.
    def destroy
      return false unless persisted?

      run_callbacks(:destroy) do
        type_header = "#{self.class.resource_name}/#{self.class.destroy_action}/#{id}"
        rk = calculate_routing_key(self.class.destroy_action, id)

        bug_bunny_client.request(type_header, exchange: current_exchange, exchange_type: current_exchange_type) do |req|
          req.routing_key = rk
        end

        self.persisted = false
      end
      true
    rescue BugBunny::ServerError, BugBunny::ClientError
      false
    end

    private

    def handle_save_response(response)
      if response['status'] == 422
        raise BugBunny::UnprocessableEntity, response['body']['errors'] || response['body']
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
