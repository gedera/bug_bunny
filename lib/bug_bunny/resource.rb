# lib/bug_bunny/resource.rb
require 'active_model'
require 'active_support/core_ext/string/inflections'
require 'uri'

module BugBunny
  # Clase base para modelos remotos que implementan el patrón **Active Record over AMQP**.
  #
  # Esta clase permite interactuar con microservicios remotos mediante RabbitMQ simulando
  # una interfaz de Active Record. Soporta **Atributos Dinámicos** (Schema-less), lo que
  # facilita la integración con APIs externas que no siguen convenciones de Rails (ej: Docker API en PascalCase).
  #
  # @example Configuración Básica (Routing Dinámico)
  #   class Node < BugBunny::Resource
  #     self.exchange = 'swarm.topic'
  #     # resource_name se infiere como 'nodes' (pluralizado)
  #     # Atributos accesibles dinámicamente: node.Hostname, node.Status
  #   end
  #
  # @example Configuración Estática (Cola Dedicada)
  #   class Manager < BugBunny::Resource
  #     self.exchange = 'swarm.direct'
  #     self.routing_key = 'manager_queue' # Todo viaja a esta cola
  #   end
  class Resource
    include ActiveModel::API
    include ActiveModel::Dirty
    include ActiveModel::Validations
    extend ActiveModel::Callbacks

    define_model_callbacks :save, :create, :update, :destroy

    # @return [ActiveSupport::HashWithIndifferentAccess] Almacén de los datos crudos del recurso.
    # @note Se llama remote_attributes para evitar conflictos con ActiveModel::AttributeSet.
    attr_reader :remote_attributes

    # @return [Boolean] Estado de persistencia del objeto (true si existe en remoto).
    attr_accessor :persisted

    class << self
      # @!group Configuración

      attr_writer :connection_pool, :exchange, :exchange_type, :resource_name, :routing_key

      # Resuelve la configuración buscando en la jerarquía de clases.
      #
      # Prioridad de resolución:
      # 1. Override temporal (Thread-local via `.with`).
      # 2. Configuración de la clase actual.
      # 3. Configuración de la clase padre (Herencia).
      #
      # @param key [Symbol] Clave única para el almacenamiento thread-local.
      # @param instance_var [Symbol] Variable de instancia a buscar (ej: :@connection_pool).
      # @return [Object, nil] El valor configurado o nil.
      # @api private
      def resolve_config(key, instance_var)
        thread_key = "bb_#{object_id}_#{key}"
        return Thread.current[thread_key] if Thread.current.key?(thread_key)

        target = self
        while target <= BugBunny::Resource
          value = target.instance_variable_get(instance_var)
          if !value.nil?
            return value.respond_to?(:call) ? value.call : value
          end
          target = target.superclass
        end
        nil
      end

      # @return [ConnectionPool] El pool de conexiones a RabbitMQ.
      def connection_pool
        resolve_config(:pool, :@connection_pool)
      end

      # @return [String] Nombre del exchange de RabbitMQ.
      # @raise [ArgumentError] Si no se ha definido el exchange.
      def current_exchange
        resolve_config(:exchange, :@exchange) || raise(ArgumentError, "Exchange not defined for #{name}")
      end

      # @return [String] Tipo de exchange ('direct', 'topic', 'fanout'). Por defecto 'direct'.
      def current_exchange_type
        resolve_config(:exchange_type, :@exchange_type) || 'direct'
      end

      # Nombre lógico del recurso. Se usa para construir la URL en el header `type`.
      # Si no se configura explícitamente, infiere el nombre de la clase y lo pluraliza.
      # @return [String] Ej: 'services' (si la clase es Manager::Service).
      def resource_name
        resolve_config(:resource_name, :@resource_name) || name.demodulize.underscore.pluralize
      end

      # Instancia el cliente RPC utilizando el pool configurado.
      # @return [BugBunny::Client]
      def bug_bunny_client
        pool = connection_pool
        raise BugBunny::Error, "Connection pool missing for #{name}" unless pool
        BugBunny::Client.new(pool: pool)
      end

      # Permite ejecutar un bloque con una configuración temporal (Thread-Safe).
      # Útil para cambiar de exchange, routing key o pool en tiempo de ejecución.
      #
      # @param exchange [String] Override del exchange.
      # @param routing_key [String] Override forzado de la routing key.
      # @param pool [ConnectionPool] Override del pool.
      # @yield Bloque de código donde aplica la configuración.
      # @return [Object] El resultado del bloque o un Proxy si no hay bloque.
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

      # Calcula la Routing Key para una acción específica.
      #
      # @param action [Symbol] La acción a realizar (:create, :update, :index, :show).
      # @param id [String, nil] El ID del recurso (opcional).
      # @return [String] La routing key calculada.
      def calculate_routing_key(action, id = nil)
        manual_rk = Thread.current["bb_#{object_id}_routing_key"]
        return manual_rk if manual_rk

        static_rk = resolve_config(:routing_key, :@routing_key)
        return static_rk if static_rk.present?

        key = "#{resource_name}.#{action}"
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

      # Busca recursos que coincidan con los filtros dados.
      # Envía una petición con header type: `resource/index?query_params`.
      #
      # @param filters [Hash] Filtros de búsqueda.
      # @return [Array<Resource>] Lista de objetos instanciados.
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

      # Retorna todos los registros del recurso remoto.
      # @return [Array<Resource>]
      def all
        where({})
      end

      # Busca un recurso por su ID.
      # Envía una petición con header type: `resource/show/:id`.
      #
      # @param id [String, Integer] ID del recurso.
      # @return [Resource, nil] El recurso encontrado o nil si retorna 404.
      def find(id)
        rk = calculate_routing_key(show_action, id)
        type_header = "#{resource_name}/#{show_action}/#{id}"

        response = bug_bunny_client.request(type_header, exchange: current_exchange, exchange_type: current_exchange_type) do |req|
          req.routing_key = rk
        end

        return nil if response.nil? || response['status'] == 404

        attributes = response['body']
        return nil unless attributes.is_a?(Hash)

        instance = new(attributes)
        instance.persisted = true
        instance.send(:clear_changes_information)
        instance
      end

      # Crea un nuevo recurso y lo persiste remotamente.
      # @param payload [Hash] Atributos iniciales.
      # @return [Resource] La instancia creada (persisted? será true si tuvo éxito).
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

    # Inicializa una nueva instancia del recurso.
    # @param attributes [Hash] Atributos iniciales (snake_case o PascalCase).
    def initialize(attributes = {})
      @remote_attributes = {}.with_indifferent_access
      @persisted = false
      assign_attributes(attributes)
      super() # Inicializa ActiveModel
    end

    # Verifica si el objeto ha sido guardado en el servicio remoto.
    def persisted?
      !!@persisted
    end

    # Asigna atributos masivamente. Utiliza los setters dinámicos.
    # @param new_attributes [Hash] Atributos a asignar.
    def assign_attributes(new_attributes)
      return if new_attributes.nil?

      new_attributes.each do |k, v|
        public_send("#{k}=", v)
      end
    end

    # Actualiza los atributos y guarda el registro.
    # @param attributes [Hash] Nuevos valores.
    # @return [Boolean] Resultado de save.
    def update(attributes)
      assign_attributes(attributes)
      save
    end

    # Calcula el payload JSON a enviar.
    # Si hay cambios (Dirty Tracking), envía solo los cambios.
    # Si es nuevo, envía todo excepto los IDs internos.
    # @return [Hash] Payload.
    def changes_to_send
      return changes.transform_values(&:last) unless changes.empty?

      @remote_attributes.except('id', 'ID', 'Id', '_id')
    end

    # @!group Atributos Dinámicos (Magic Methods)

    # Intercepta llamadas a métodos desconocidos para leer/escribir en @remote_attributes.
    # Permite acceder a propiedades como `node.Hostname` o `node.Spec` dinámicamente.
    def method_missing(method_name, *args, &block)
      attribute_name = method_name.to_s

      if attribute_name.end_with?('=')
        # Setter: node.Status = 'active'
        key = attribute_name.chop
        val = args.first

        # Dirty Tracking manual
        attribute_will_change!(key) unless @remote_attributes[key] == val

        @remote_attributes[key] = val
      else
        # Getter: node.Status
        if @remote_attributes.key?(attribute_name)
          @remote_attributes[attribute_name]
        else
          super
        end
      end
    end

    # @api private
    def respond_to_missing?(method_name, include_private = false)
      @remote_attributes.key?(method_name.to_s.sub(/=$/, '')) || super
    end

    # Retorna el ID del recurso buscando en variantes comunes (id, ID, Id, _id).
    # @return [String, Integer, nil]
    def id
      @remote_attributes['id'] || @remote_attributes['ID'] || @remote_attributes['Id'] || @remote_attributes['_id']
    end

    # Asigna el ID manualmente.
    # @param value [Object] Nuevo ID.
    def id=(value)
      @remote_attributes['id'] = value
    end

    # Método requerido por ActiveModel::Validations para leer atributos.
    # @param attr [Symbol] Nombre del atributo.
    # @return [Object] Valor del atributo.
    # @api private
    def read_attribute_for_validation(attr)
      @remote_attributes[attr.to_s]
    end

    # @!group Persistencia

    # Guarda el recurso en el servicio remoto (Create o Update).
    #
    # * Create: POST a `resource/create`
    # * Update: POST a `resource/update/:id`
    #
    # @return [Boolean] true si fue exitoso, false si hubo error de validación o red.
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
          req.body = changes_to_send
        end

        handle_save_response(response)
      end
    rescue BugBunny::UnprocessableEntity => e
      load_remote_rabbit_errors(e.error_messages)
      false
    end

    # Elimina el recurso remoto.
    # Envía petición a `resource/destroy/:id`.
    # @return [Boolean] true si fue eliminado exitosamente.
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

    # Procesa la respuesta exitosa del servidor RPC.
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

    # Carga errores remotos en el objeto local ActiveModel::Errors.
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
