# frozen_string_literal: true

require 'active_model'
require 'active_support/core_ext/string/inflections'
require 'uri'
require 'set' # Necesario para el tracking manual

module BugBunny
  # Clase base para modelos remotos que implementan **Active Record over AMQP (RESTful)**.
  #
  # Soporta un esquema híbrido de datos y configuración de infraestructura en cascada:
  # 1. **Defaults:** Definidos en la sesión.
  # 2. **Global:** Definidos en BugBunny.configuration.
  # 3. **Específico:** Definidos en la clase del recurso o vía `with`.
  #
  # @author Gabriel
  # @since 3.1.2
  class Resource
    include ActiveModel::API
    include ActiveModel::Attributes
    include ActiveModel::Dirty
    include ActiveModel::Validations
    extend ActiveModel::Callbacks

    define_model_callbacks :save, :create, :update, :destroy

    attr_reader :remote_attributes
    attr_accessor :persisted, :routing_key, :exchange, :exchange_type

    # @return [Hash] Opciones específicas de instancia para exchange y queue.
    attr_accessor :exchange_options, :queue_options

    class << self
      attr_writer :connection_pool, :exchange, :exchange_type, :resource_name, :routing_key, :param_key

      # @!group Configuración de Infraestructura Específica
      attr_writer :exchange_options, :queue_options

      # @api private
      def thread_config(key)
        Thread.current["bb_#{object_id}_#{key}"]
      end

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
      def connection_pool
        resolve_config(:pool, :@connection_pool)
      end

      # @return [String] Nombre del exchange actual.
      def current_exchange
        resolve_config(:exchange, :@exchange) || raise(ArgumentError, "Exchange not defined for #{name}")
      end

      # @return [String] Tipo de exchange ('direct', 'topic', 'fanout').
      def current_exchange_type
        resolve_config(:exchange_type, :@exchange_type) || 'direct'
      end

      # @return [Hash] Opciones de exchange específicas (Nivel 3 de la cascada).
      def current_exchange_options
        resolve_config(:exchange_options, :@exchange_options) || {}
      end

      # @return [Hash] Opciones de cola específicas.
      def current_queue_options
        resolve_config(:queue_options, :@queue_options) || {}
      end

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

      # Instancia el cliente inyectando los middlewares núcleo y personalizados.
      # Integra automáticamente `RaiseError` y `JsonResponse` para que el ORM trabaje
      # puramente con datos parseados o atrape excepciones sin validar HTTP Status manuales.
      #
      # @return [BugBunny::Client]
      def bug_bunny_client
        pool = connection_pool
        raise BugBunny::Error, "Connection pool missing for #{name}" unless pool

        BugBunny::Client.new(pool: pool) do |stack|
          # 1. Middlewares Core (Siempre presentes para el Resource)
          stack.use BugBunny::Middleware::RaiseError
          stack.use BugBunny::Middleware::JsonResponse

          # 2. Middlewares Personalizados del Usuario
          resolve_middleware_stack.each { |block| block.call(stack) }
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
      def with(exchange: nil, routing_key: nil, exchange_type: nil, pool: nil, exchange_options: nil,
               queue_options: nil)
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
      # Solo puede usarse para UNA llamada de método: el contexto se restaura al finalizar.
      class ScopeProxy < BasicObject
        def initialize(target, keys, old_values)
          @target = target
          @keys = keys
          @old_values = old_values
          @used = false
        end

        def method_missing(method, *args, &block)
          ::Kernel.raise ::BugBunny::Error, 'ScopeProxy is single-use. Call .with again for a new context.' if @used
          @used = true
          @target.public_send(method, *args, &block)
        ensure
          @keys.each { |k, v| ::Thread.current[v] = @old_values[k] }
        end
      end

      # Calcula la routing key final.
      # @param id [String, nil] ID del recurso.
      # @return [String]
      def calculate_routing_key(_id = nil)
        manual_rk = thread_config(:routing_key)
        return manual_rk if manual_rk

        static_rk = resolve_config(:routing_key, :@routing_key)
        return static_rk if static_rk.present?

        resource_name
      end

      # @!group Acciones CRUD RESTful

      # Realiza una búsqueda filtrada (GET).
      # Mapea un posible 404 a un array vacío.
      #
      # @param filters [Hash]
      # @return [Array<BugBunny::Resource>]
      def where(filters = {})
        rk = calculate_routing_key

        response = bug_bunny_client.request(
          resource_name,
          method: :get,
          exchange: current_exchange,
          exchange_type: current_exchange_type,
          routing_key: rk,
          exchange_options: current_exchange_options,
          queue_options: current_queue_options,
          params: filters.presence || {}
        )

        return [] unless response['body'].is_a?(Array)

        response['body'].map do |attrs|
          inst = new(attrs)
          inst.persisted = true
          inst.send(:clear_changes_information)
          inst
        end
      rescue BugBunny::NotFound
        []
      end

      # Devuelve todos los registros.
      # @return [Array<BugBunny::Resource>]
      def all
        where({})
      end

      # Busca un registro por ID (GET).
      # Mapea un 404 (NotFound) devolviendo un objeto nulo.
      #
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

        return nil unless response && response['body'].is_a?(Hash)

        instance = new(response['body'])
        instance.persisted = true
        instance.send(:clear_changes_information)
        instance
      rescue BugBunny::NotFound
        nil
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
      @extra_attributes = {}.with_indifferent_access
      @dynamic_changes = Set.new
      @persisted = false

      # Contexto de infraestructura
      @routing_key = self.class.thread_config(:routing_key)
      @exchange = self.class.thread_config(:exchange)
      @exchange_type = self.class.thread_config(:exchange_type)
      @exchange_options = self.class.thread_config(:exchange_options) || self.class.current_exchange_options
      @queue_options = self.class.thread_config(:queue_options) || self.class.current_queue_options

      super
    end

    # Limpia el rastreo de ActiveModel y nuestro rastreo dinámico interno.
    def clear_changes_information
      super
      @dynamic_changes.clear
    end

    # @return [Boolean] true si hay cambios nativos o dinámicos.
    def changed?
      super || @dynamic_changes.any?
    end

    # @return [Array<String>] Lista de atributos que han cambiado.
    def changed
      (super + @dynamic_changes.to_a).uniq
    end

    # Serialización combinada.
    # @return [Hash]
    def attributes_for_serialization
      @extra_attributes.merge(attributes)
    end

    # @return [String]
    def calculate_routing_key(id = nil)
      @routing_key || self.class.calculate_routing_key(id)
    end

    # @return [String]
    def current_exchange
      @exchange || self.class.current_exchange
    end

    # @return [String]
    def current_exchange_type
      @exchange_type || self.class.current_exchange_type
    end

    # @return [BugBunny::Client]
    def bug_bunny_client
      self.class.bug_bunny_client
    end

    # @return [Boolean]
    def persisted?
      !!@persisted
    end

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
      # 1. Obtener los nombres de todos los atributos que han cambiado (incluyendo dinámicos vía attribute_will_change!)
      changed_keys = changed

      # 2. Construir el payload con los valores actuales de esas keys
      payload = {}
      changed_keys.each do |key|
        payload[key] = public_send(key)
      end

      return payload unless payload.empty?

      # Fallback: Si no hay cambios detectados (ej: en un create), enviamos todo
      attributes_for_serialization.except('id', 'ID', 'Id', '_id')
    end

    # Intercepta asignaciones dinámicas y las registra como cambios.
    def method_missing(method_name, *args, &block)
      attribute_name = method_name.to_s
      if attribute_name.end_with?('=')
        key = attribute_name.chop
        val = args.first

        if @extra_attributes[key] != val
          @dynamic_changes << key
          @extra_attributes[key] = val
        end
      else
        @extra_attributes.key?(attribute_name) ? @extra_attributes[attribute_name] : super
      end
    end

    def respond_to_missing?(method_name, include_private = false)
      @extra_attributes.key?(method_name.to_s.sub(/=$/, '')) || super
    end

    # @return [Object] Valor del ID buscando en múltiples nomenclaturas.
    def id
      attributes['id'] || @extra_attributes['id'] || @extra_attributes['ID'] || @extra_attributes['Id'] || @extra_attributes['_id']
    end

    def id=(value)
      if self.class.attribute_names.include?('id')
        super
      else
        @dynamic_changes << 'id' if @extra_attributes['id'] != value
        @extra_attributes['id'] = value
      end
    end

    def read_attribute_for_validation(attr)
      attr_s = attr.to_s
      self.class.attribute_names.include?(attr_s) ? attribute(attr_s) : @extra_attributes[attr_s]
    end

    # @!group Persistencia

    # Guarda el recurso en el servidor remoto vía AMQP (POST o PUT).
    # Asume el Happy Path; el middleware se encarga de interceptar y lanzar excepciones.
    #
    # @return [Boolean] Retorna true si tuvo éxito, false si falló la validación.
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

        # Si el middleware de errores no lanza excepción, asumimos un éxito (200..299)
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

        assign_attributes(response['body'])
        self.persisted = true
        clear_changes_information
        true
      end
    rescue BugBunny::UnprocessableEntity => e
      load_remote_rabbit_errors(e.error_messages)
      false
    end

    # Elimina el recurso del servidor remoto (DELETE).
    #
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

    # Carga errores remotos en el objeto local (utilizado al recibir 422).
    def load_remote_rabbit_errors(errors_hash)
      return if errors_hash.nil? || errors_hash.empty?

      if errors_hash.is_a?(String)
        errors.add(:base, errors_hash)
      else
        errors_hash.each { |attr, msg| Array(msg).each { |m| errors.add(attr, m) } }
      end
    end
  end
end
