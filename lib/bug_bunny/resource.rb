# frozen_string_literal: true

require 'active_model'
require 'active_support/core_ext/string/inflections'
require 'uri'
require 'set' # Necesario para el tracking manual
require 'rack/utils'

module BugBunny
  # Clase base para modelos remotos que implementan **Active Record over AMQP (RESTful)**.
  #
  # Soporta un esquema híbrido de datos y configuración de infraestructura en cascada:
  # 1. **Defaults:** Definidos en la sesión.
  # 2. **Global:** Definidos en BugBunny.configuration.
  # 3. **Específico:** Definidos en la clase del recurso o vía `with`.
  #
  # @author Gabriel
  # @since 3.1.0
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

    # @return [Hash] Opciones específicas de instancia para exchange y queue.
    attr_accessor :exchange_options, :queue_options

    class << self
      attr_writer :connection_pool, :exchange, :exchange_type, :resource_name, :routing_key, :param_key

      # @!group Configuración de Infraestructura Específica
      attr_writer :exchange_options, :queue_options

      # @api private
      def thread_config(key); Thread.current["bb_#{object_id}_#{key}"]; end

      # Resuelve la configuración buscando en el hilo, luego en la jerarquía de clases.
      # @param key [Symbol] Clave en el Thread.current.
      # @param instance_var [Symbol] Nombre de la variable de instancia en la clase.
      # @return [Object, nil]
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

      # @return [ConnectionPool, nil]
      def connection_pool; resolve_config(:pool, :@connection_pool); end

      # @return [String] Nombre del exchange actual.
      def current_exchange; resolve_config(:exchange, :@exchange) || raise(ArgumentError, "Exchange not defined for #{name}"); end

      # @return [String] Tipo de exchange ('direct', 'topic', 'fanout').
      def current_exchange_type; resolve_config(:exchange_type, :@exchange_type) || 'direct'; end

      # @return [Hash] Opciones de exchange específicas (Nivel 3 de la cascada).
      def current_exchange_options; resolve_config(:exchange_options, :@exchange_options) || {}; end

      # @return [Hash] Opciones de cola específicas.
      def current_queue_options; resolve_config(:queue_options, :@queue_options) || {}; end

      # @return [String] Nombre del recurso para la construcción de rutas.
      def resource_name
        resolve_config(:resource_name, :@resource_name) || name.demodulize.underscore.pluralize
      end

      # @return [String] Clave raíz para envolver el payload en las peticiones.
      def param_key
        resolve_config(:param_key, :@param_key) || model_name.element
      end

      # @api private
      def client_middleware(&block)
        @client_middleware_stack ||= []
        @client_middleware_stack << block
      end

      # @api private
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

      # Instancia el cliente inyectando los middlewares configurados.
      # @return [BugBunny::Client]
      def bug_bunny_client
        pool = connection_pool
        raise BugBunny::Error, "Connection pool missing for #{name}" unless pool
        BugBunny::Client.new(pool: pool) do |conn|
          resolve_middleware_stack.each { |block| block.call(conn) }
        end
      end

      # Permite configurar dinámicamente el contexto AMQP para una operación.
      #
      # @param exchange [String] Nombre del exchange.
      # @param routing_key [String] Routing key manual.
      # @param exchange_type [String] Tipo de exchange.
      # @param pool [ConnectionPool] Pool de conexiones.
      # @param exchange_options [Hash] Opciones de infraestructura.
      # @param queue_options [Hash] Opciones de cola.
      def with(exchange: nil, routing_key: nil, exchange_type: nil, pool: nil, exchange_options: nil, queue_options: nil)
        keys = {
          exchange: "bb_#{object_id}_exchange",
          exchange_type: "bb_#{object_id}_exchange_type",
          pool: "bb_#{object_id}_pool",
          routing_key: "bb_#{object_id}_routing_key",
          exchange_options: "bb_#{object_id}_exchange_options",
          queue_options: "bb_#{object_id}_queue_options"
        }
        old_values = {}
        keys.each { |k, v| old_values[k] = Thread.current[v] }

        Thread.current[keys[:exchange]] = exchange if exchange
        Thread.current[keys[:exchange_type]] = exchange_type if exchange_type
        Thread.current[keys[:pool]] = pool if pool
        Thread.current[keys[:routing_key]] = routing_key if routing_key
        Thread.current[keys[:exchange_options]] = exchange_options if exchange_options
        Thread.current[keys[:queue_options]] = queue_options if queue_options

        if block_given?
          begin; yield; ensure; keys.each { |k, v| Thread.current[v] = old_values[k] }; end
        else
          ScopeProxy.new(self, keys, old_values)
        end
      end

      # Proxy para el encadenamiento del método `.with`.
      class ScopeProxy < BasicObject
        def initialize(target, keys, old_values); @target = target; @keys = keys; @old_values = old_values; end
        def method_missing(method, *args, &block); @target.public_send(method, *args, &block); ensure; @keys.each { |k, v| ::Thread.current[v] = @old_values[k] }; end
      end

      # Calcula la routing key final.
      # @param id [String, nil] ID del recurso.
      # @return [String]
      def calculate_routing_key(id = nil)
        manual_rk = thread_config(:routing_key)
        return manual_rk if manual_rk
        static_rk = resolve_config(:routing_key, :@routing_key)
        return static_rk if static_rk.present?
        resource_name
      end

      # @!group Acciones CRUD RESTful

      # Realiza una búsqueda filtrada (GET).
      # @param filters [Hash]
      # @return [Array<BugBunny::Resource>]
      def where(filters = {})
        rk = calculate_routing_key
        path = resource_name
        path += "?#{Rack::Utils.build_nested_query(filters)}" if filters.present?

        response = bug_bunny_client.request(
          path,
          method: :get,
          exchange: current_exchange,
          exchange_type: current_exchange_type,
          routing_key: rk,
          exchange_options: current_exchange_options,
          queue_options: current_queue_options
        )

        return [] unless response['body'].is_a?(Array)
        response['body'].map do |attrs|
          inst = new(attrs)
          inst.persisted = true
          inst.send(:clear_changes_information)
          inst
        end
      end

      # Devuelve todos los registros.
      # @return [Array<BugBunny::Resource>]
      def all; where({}); end

      # Busca un registro por ID (GET).
      # @param id [String, Integer]
      # @return [BugBunny::Resource, nil]
      def find(id)
        rk = calculate_routing_key(id)
        path = "#{resource_name}/#{id}"

        response = bug_bunny_client.request(
          path,
          method: :get,
          exchange: current_exchange,
          exchange_type: current_exchange_type,
          routing_key: rk,
          exchange_options: current_exchange_options,
          queue_options: current_queue_options
        )

        return nil if response.nil? || response['status'] == 404
        return nil unless response['body'].is_a?(Hash)
        instance = new(response['body'])
        instance.persisted = true
        instance.send(:clear_changes_information)
        instance
      end

      # Crea una nueva instancia y la persiste.
      # @param payload [Hash]
      # @return [BugBunny::Resource]
      def create(payload)
        instance = new(payload)
        instance.save
        instance
      end
    end

    # @!group Instancia

    # Inicializa el recurso.
    # @param attributes [Hash]
    def initialize(attributes = {})
      @remote_attributes = {}.with_indifferent_access
      @dynamic_changes = Set.new # Rastreo manual para atributos dinámicos
      @persisted = false

      # Contexto de infraestructura
      @routing_key = self.class.thread_config(:routing_key)
      @exchange = self.class.thread_config(:exchange)
      @exchange_type = self.class.thread_config(:exchange_type)
      @exchange_options = self.class.thread_config(:exchange_options) || self.class.current_exchange_options
      @queue_options = self.class.thread_config(:queue_options) || self.class.current_queue_options

      super()
      assign_attributes(attributes)
    end

    # Limpia tanto el rastreo de ActiveModel como nuestro rastreo dinámico.
    def clear_changes_information
      super
      @dynamic_changes.clear
    end

    # Serialización combinada.
    # @return [Hash]
    def attributes_for_serialization
      @remote_attributes.merge(attributes)
    end

    # @return [String]
    def calculate_routing_key(id=nil); @routing_key || self.class.calculate_routing_key(id); end

    # @return [String]
    def current_exchange; @exchange || self.class.current_exchange; end

    # @return [String]
    def current_exchange_type; @exchange_type || self.class.current_exchange_type; end

    # @return [BugBunny::Client]
    def bug_bunny_client; self.class.bug_bunny_client; end

    # @return [Boolean]
    def persisted?; !!@persisted; end

    # Asignación masiva de atributos.
    # @param new_attributes [Hash]
    def assign_attributes(new_attributes)
      return if new_attributes.nil?
      new_attributes.each { |k, v| public_send("#{k}=", v) }
    end

    # Actualiza y guarda.
    # @param attributes [Hash]
    # @return [Boolean]
    def update(attributes)
      assign_attributes(attributes)
      save
    end

    # Retorna el hash combinado de cambios (Tipados + Dinámicos).
    # @return [Hash]
    def changes_to_send
      # 1. Cambios de ActiveModel (Tipados)
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

    # @return [Object] Valor del ID buscando en múltiples nomenclaturas.
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

    # Guarda el recurso en el servidor remoto vía AMQP (POST o PUT).
    # @return [Boolean]
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
          exchange_options: @exchange_options,
          queue_options: @queue_options,
          body: wrapped_payload
        )

        handle_save_response(response)
      end
    rescue BugBunny::UnprocessableEntity => e
      load_remote_rabbit_errors(e.error_messages)
      false
    end

    # Elimina el recurso del servidor remoto (DELETE).
    # @return [Boolean]
    def destroy
      return false unless persisted?
      run_callbacks(:destroy) do
        path = "#{self.class.resource_name}/#{id}"
        rk = calculate_routing_key(id)

        bug_bunny_client.request(
          path,
          method: :delete,
          exchange: current_exchange,
          exchange_type: current_exchange_type,
          routing_key: rk,
          exchange_options: @exchange_options,
          queue_options: @queue_options
        )

        self.persisted = false
      end
      true
    rescue BugBunny::ServerError, BugBunny::ClientError
      false
    end

    private

    # Maneja la lógica de respuesta para la acción de guardado.
    def handle_save_response(response)
      if response['status'] == 422
        raise BugBunny::UnprocessableEntity.new(response['body']['errors'] || response['body'])
      elsif response['status'] >= 500
        raise BugBunny::InternalServerError, format_error_message(response['body'])
      elsif response['status'] >= 400
        raise BugBunny::ClientError, format_error_message(response['body'])
      end

      assign_attributes(response['body'])
      self.persisted = true
      clear_changes_information
      true
    end

    # Formatea el cuerpo de la respuesta de error para que sea legible en las excepciones
    def format_error_message(body)
      return "Unknown Error" if body.nil?
      return body if body.is_a?(String)

      # Si el worker devolvió un JSON con una key 'error' (nuestra convención en Controller), la priorizamos
      if body.is_a?(Hash) && body['error']
        detail = body['detail'] ? " - #{body['detail']}" : ""
        "#{body['error']}#{detail}"
      else
        # Fallback: Convertir todo el Hash a JSON string para que se vea claro en Sentry/Logs
        body.to_json
      end
    end

    # Carga errores remotos en el objeto local.
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
