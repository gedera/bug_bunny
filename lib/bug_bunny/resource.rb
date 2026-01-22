# lib/bug_bunny/resource.rb
require 'active_model'
require 'active_support/core_ext/string/inflections'
require 'uri'

module BugBunny
  # Clase base para modelos remotos (RPC over AMQP).
  #
  # Esta clase maneja la comunicación con microservicios.
  # Soporta dos estrategias de ruteo:
  # 1. **Estático (Direct):** Se define una `routing_key` fija (ej: 'manager').
  # 2. **Dinámico (Topic):** Se genera `resource_name.action` (ej: 'users.create').
  #
  # En ambos casos, la intención de la acción viaja en el header `type` (URL simulada).
  class Resource
    include ActiveModel::API
    include ActiveModel::Attributes
    include ActiveModel::Dirty
    include ActiveModel::Validations
    extend ActiveModel::Callbacks

    define_model_callbacks :save, :create, :update, :destroy

    class << self
      # @!group Configuración

      # Eliminamos routing_key_prefix por ser redundante.
      attr_writer :connection_pool, :exchange, :exchange_type, :resource_name, :routing_key

      # Helper para resolver configuración (Thread-local > Clase).
      # @api private
      def resolve_config(key, instance_var)
        thread_key = "bb_#{object_id}_#{key}"
        return Thread.current[thread_key] if Thread.current.key?(thread_key)
        value = instance_variable_get(instance_var)
        value.respond_to?(:call) ? value.call : value
      end

      def connection_pool; resolve_config(:pool, :@connection_pool); end
      def current_exchange; resolve_config(:exchange, :@exchange) || raise(ArgumentError, "Exchange not defined"); end
      def current_exchange_type; resolve_config(:exchange_type, :@exchange_type) || 'direct'; end

      # Nombre del recurso. Se usa para:
      # 1. Construir la URL en el header `type` (ej: 'users/create').
      # 2. Generar la routing key dinámica si no hay una fija (ej: 'users.create').
      # @return [String] Ej: 'users' o 'box_manager'.
      def resource_name
        resolve_config(:resource_name, :@resource_name) || name.demodulize.underscore
      end

      # @return [BugBunny::Client]
      def bug_bunny_client
        pool = connection_pool
        raise BugBunny::Error, "Connection pool missing for #{name}" unless pool
        BugBunny::Client.new(pool: pool)
      end

      # Override temporal (Thread-safe).
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

      # Calcula la Routing Key final.
      #
      # Lógica simplificada:
      # 1. Si hay una `routing_key` explícita (configurada o via .with), ÚSALA.
      # 2. Si no, GENÉRALA usando `resource_name.action`.
      #
      # @param action [Symbol] La acción (ej: :create).
      # @param id [String, nil] ID opcional (solo para routing dinámico).
      # @return [String]
      def calculate_routing_key(action, id = nil)
        # 1. Estrategia Estática (Explícita)
        # Busca override temporal O valor de clase (self.routing_key = 'manager')
        static_rk = resolve_config(:routing_key, :@routing_key)

        # Override temporal tiene prioridad (se resuelve en resolve_config primero via thread)
        manual_rk = Thread.current["bb_#{object_id}_routing_key"]
        return manual_rk if manual_rk
        return static_rk if static_rk.present?

        # 2. Estrategia Dinámica (Fallback por defecto)
        # Usa el resource_name como prefijo: 'users' -> 'users.create'
        key = "#{resource_name}.#{action}"
        key = "#{key}.#{id}" if id
        key
      end

      # @!group Acciones CRUD

      def index_action; :index; end
      def show_action; :show; end
      def create_action; :create; end
      def update_action; :update; end
      def destroy_action; :destroy; end

      # Recupera colección.
      # Header Type: `resource/index?query`
      # Routing Key: `routing_key` (fija) o `resource.index` (dinámica).
      def where(filters = {})
        rk = calculate_routing_key(index_action)
        path = "#{resource_name}/#{index_action}"

        if filters.present?
          query_string = URI.encode_www_form(filters)
          type_header = "#{path}?#{query_string}"
        else
          type_header = path
        end

        response = bug_bunny_client.request(type_header, exchange: current_exchange, exchange_type: current_exchange_type) do |req|
          req.routing_key = rk
        end

        return [] unless response['body'].is_a?(Array)

        response['body'].map do |attrs|
          inst = new(attrs)
          inst.persisted = true
          inst.send(:clear_changes_information)
          inst
        end
      end

      def all; where({}); end

      # Busca por ID.
      # Header Type: `resource/show/id`
      # Routing Key: `routing_key` (fija) o `resource.show.id` (dinámica).
      def find(id)
        rk = calculate_routing_key(show_action, id)
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

      def create(payload)
        instance = new(payload)
        instance.save
        instance
      end
    end

    # @!group Instancia

    def current_exchange; self.class.current_exchange; end
    def current_exchange_type; self.class.current_exchange_type; end
    def calculate_routing_key(action, id=nil); self.class.calculate_routing_key(action, id); end
    def bug_bunny_client; self.class.bug_bunny_client; end

    attribute :persisted, :boolean, default: false

    def initialize(attributes = {})
      super(attributes)
      @previously_persisted = persisted
    end

    def persisted?; persisted; end

    def assign_attributes(new_attributes)
      return if new_attributes.nil?
      super(new_attributes)
    end

    def update(attributes)
      assign_attributes(attributes)
      save
    end

    def changes_to_send
      changes.transform_values(&:last).except(:persisted)
    end

    def save
      return false unless valid?

      run_callbacks(:save) do
        is_new = !persisted?
        action_verb = is_new ? self.class.create_action : self.class.update_action

        if is_new
          type_header = "#{self.class.resource_name}/#{action_verb}"
          # Si hay RK fija, usa esa. Si no, usa resource.create
          rk = calculate_routing_key(action_verb)
        else
          type_header = "#{self.class.resource_name}/#{action_verb}/#{id}"
          # Si hay RK fija, usa esa. Si no, usa resource.update.id
          rk = calculate_routing_key(action_verb, id)
        end

        response = bug_bunny_client.request(type_header, exchange: current_exchange, exchange_type: current_exchange_type) do |req|
          req.routing_key = rk
          req.body = changes_to_send
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
