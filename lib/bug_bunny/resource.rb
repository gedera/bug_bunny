# lib/bug_bunny/resource.rb
require 'active_model'
require 'active_support/core_ext/string/inflections'

module BugBunny
  # Clase base para modelos remotos (ORM sobre AMQP).
  #
  # Provee una interfaz similar a ActiveRecord/ActiveResource para interactuar
  # con servicios remotos utilizando RabbitMQ como transporte.
  # Implementa características clave como:
  # * Mapeo de atributos (ActiveModel::Attributes)
  # * Rastreo de cambios (ActiveModel::Dirty)
  # * Validaciones (ActiveModel::Validations)
  # * Configuración dinámica y segura por hilo.
  #
  # @example Definición de un modelo
  #   class User < BugBunny::Resource
  #     self.exchange = 'users.topic'
  #     self.exchange_type = 'topic'
  #     self.routing_key_prefix = 'users'
  #
  #     attribute :id, :integer
  #     attribute :name, :string
  #     attribute :email, :string
  #
  #     validates :email, presence: true
  #   end
  class Resource
    include ActiveModel::API
    include ActiveModel::Attributes
    include ActiveModel::Dirty
    include ActiveModel::Validations

    class << self
      # @!group Configuración

      # Permite inyectar dependencias y configuración (Pool, Exchange, etc).
      # @api private
      attr_writer :connection_pool, :exchange, :exchange_type, :routing_key_prefix, :resource_name

      # Resuelve la configuración buscando en una jerarquía de prioridades.
      #
      # Orden de precedencia:
      # 1. Overrides temporales (Thread-local vía .with)
      # 2. Valores de clase base.
      # 3. Ejecución de Procs/Lambdas (para config dinámica).
      #
      # @param key [Symbol] Clave interna del override para el thread local.
      # @param instance_var [Symbol] Nombre de la variable de instancia de fallback.
      # @return [Object] El valor de configuración resuelto.
      # @api private
      def resolve_config(key, instance_var)
        thread_key = "bb_#{object_id}_#{key}"
        return Thread.current[thread_key] if Thread.current.key?(thread_key)

        value = instance_variable_get(instance_var)
        value.respond_to?(:call) ? value.call : value
      end

      # @return [ConnectionPool] El pool de conexiones a utilizar.
      def connection_pool
        resolve_config(:pool, :@connection_pool)
      end

      # @return [String] El nombre del exchange actual.
      # @raise [ArgumentError] Si no se ha definido un exchange.
      def current_exchange
        resolve_config(:exchange, :@exchange) || raise(ArgumentError, "Exchange not defined for #{name}")
      end

      # @return [String] El tipo de exchange (default: 'direct').
      def current_exchange_type
        resolve_config(:exchange_type, :@exchange_type) || 'direct'
      end

      # @return [String, nil] El prefijo para las routing keys (ej: 'users' -> 'users.create').
      def current_routing_key_prefix
        resolve_config(:prefix, :@routing_key_prefix)
      end

      # @return [String] El nombre del recurso inferido de la clase (ej: 'User' -> 'user').
      def resource_name
        @resource_name ||= name.demodulize.underscore
      end

      # Instancia un cliente ligero para realizar peticiones.
      # @return [BugBunny::Client] Cliente configurado con el pool actual.
      # @raise [BugBunny::Error] Si el connection_pool no está configurado.
      def bug_bunny_client
        pool = connection_pool
        raise BugBunny::Error, "connection_pool not configured for #{name}" unless pool
        BugBunny::Client.new(pool: pool)
      end

      # Permite cambiar la configuración del recurso temporalmente dentro de un bloque o cadena.
      #
      # Utiliza variables Thread-local para asegurar que el cambio solo afecte al hilo actual
      # y a la operación en curso, siendo seguro para servidores web concurrentes (Puma).
      #
      # @example Uso con bloque
      #   User.with(exchange: 'staging') do
      #     User.find(1)
      #   end
      #
      # @example Uso encadenado (Fluent Interface)
      #   User.with(routing_key: 'custom.route').create(name: 'Test')
      #
      # @param exchange [String, nil] Override del exchange.
      # @param routing_key [String, nil] Override forzado de la routing key.
      # @param exchange_type [String, nil] Override del tipo de exchange.
      # @param pool [ConnectionPool, nil] Override del pool.
      # @return [Class, ScopeProxy] Retorna self (si hay bloque) o un Proxy para encadenar métodos.
      def with(exchange: nil, routing_key: nil, exchange_type: nil, pool: nil)
        keys = {
          exchange: "bb_#{object_id}_exchange",
          exchange_type: "bb_#{object_id}_exchange_type",
          pool: "bb_#{object_id}_pool",
          routing_key: "bb_#{object_id}_routing_key"
        }

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

      # Proxy interno para limpiar las variables thread-local automáticamente tras la ejecución
      # de un método encadenado.
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

      # Calcula la routing key final basada en la acción y el prefijo.
      #
      # @param action [Symbol, String] La acción (ej: :create).
      # @return [String] Routing key (ej: 'users.create').
      def calculate_routing_key(action)
        manual_rk = Thread.current["bb_#{object_id}_routing_key"]
        return manual_rk if manual_rk

        prefix = current_routing_key_prefix
        return action.to_s unless prefix

        "#{prefix}.#{action}"
      end

      # @!group Acciones CRUD

      # Verbos de acción RESTful mapeados a acciones AMQP.
      def index_action; :index; end
      def show_action; :show; end
      def create_action; :create; end
      def update_action; :update; end
      def destroy_action; :destroy; end

      # Busca un recurso remoto por su ID mediante una petición RPC.
      #
      # @param id [Integer, String] El ID del recurso.
      # @return [Resource, nil] La instancia hidratada o nil si no existe (404).
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

      # Crea y persiste un nuevo recurso remoto.
      #
      # @param payload [Hash] Atributos iniciales del recurso.
      # @return [Resource] La instancia creada. Verificar {#persisted?} para confirmar éxito.
      def create(payload)
        instance = new(payload)
        instance.save
        instance
      end
    end

    # @!group Instancia

    # Delegadores a métodos de clase para conveniencia interna.
    def current_exchange; self.class.current_exchange; end
    def current_exchange_type; self.class.current_exchange_type; end
    def calculate_routing_key(action); self.class.calculate_routing_key(action); end
    def bug_bunny_client; self.class.bug_bunny_client; end

    # @return [Boolean] Indica si el recurso ya existe en el backend remoto.
    attribute :persisted, :boolean, default: false

    def initialize(attributes = {})
      super(attributes)
      @previously_persisted = persisted
    end

    # Alias para compatibilidad con form_for y helpers de Rails.
    # @return [Boolean]
    def persisted?
      persisted
    end

    # Asigna atributos masivamente de forma segura.
    # @param new_attributes [Hash] Nuevos valores.
    def assign_attributes(new_attributes)
      return if new_attributes.nil?
      new_attributes.each do |k, v|
        setter = "#{k}="
        public_send(setter, v) if respond_to?(setter)
      end
    end

    # Calcula el payload a enviar basándose solo en los atributos modificados (Dirty Tracking).
    # @return [Hash] Atributos que han cambiado.
    def changes_to_send
      attrs = {}
      changes.each do |attr, vals|
        next if attr.to_sym == :persisted
        attrs[attr] = vals[1]
      end
      attrs
    end

    # Guarda el registro (Create o Update) enviando un mensaje RPC.
    #
    # Maneja automáticamente:
    # * Errores de validación (422): puebla el objeto `errors`.
    # * Actualización de atributos con la respuesta del servidor.
    # * Limpieza del estado "dirty" tras guardar.
    #
    # @return [Boolean] true si tuvo éxito, false si hubo error de validación.
    # @raise [BugBunny::InternalServerError] Si el servidor falla (500).
    # @raise [BugBunny::ClientError] Si hay un error de petición genérico (400).
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

    # Elimina el registro remoto.
    #
    # @return [Boolean] true si se eliminó correctamente.
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

    # Puebla el objeto `errors` de ActiveModel con los errores recibidos del servidor.
    # @param errors_hash [Hash, String] Errores recibidos.
    # @api private
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
