# lib/bug_bunny/resource.rb
require 'active_model'
require 'active_support/core_ext/string/inflections'
require 'uri'

module BugBunny
  # Clase base para modelos remotos que implementan **Active Record over AMQP (RESTful)**.
  #
  # Esta clase transforma operaciones CRUD estándar en peticiones RPC utilizando
  # verbos HTTP semánticos (GET, POST, PUT, DELETE) transportados sobre headers AMQP.
  #
  # También gestiona la serialización automática de parámetros ("wrapping") para
  # compatibilidad con Strong Parameters de Rails.
  #
  # @example Definición de un recurso
  #   class User < BugBunny::Resource
  #     self.exchange = 'app.topic'
  #     self.resource_name = 'users'
  #     # Opcional: Personalizar la clave raíz del JSON
  #     self.param_key = 'user_data' 
  #   end
  #
  # @example Uso con contexto temporal
  #   # La instancia 'user' recordará que debe usar la routing_key 'urgent'
  #   user = User.with(routing_key: 'urgent').new(name: 'Gaby')
  #   user.save # Enviará a la cola 'urgent' aunque estemos fuera del bloque .with
  class Resource
    include ActiveModel::API
    include ActiveModel::Dirty
    include ActiveModel::Validations
    extend ActiveModel::Callbacks

    define_model_callbacks :save, :create, :update, :destroy

    # @return [HashWithIndifferentAccess] Contenedor de los atributos remotos (JSON crudo).
    attr_reader :remote_attributes
    
    # @return [Boolean] Indica si el objeto ha sido guardado en el servicio remoto.
    attr_accessor :persisted

    # @return [String, nil] Routing Key capturada en el momento de la instanciación.
    attr_accessor :routing_key
    
    # @return [String, nil] Exchange capturado en el momento de la instanciación.
    attr_accessor :exchange
    
    # @return [String, nil] Tipo de Exchange capturado en el momento de la instanciación.
    attr_accessor :exchange_type

    class << self
      # Configuración heredable
      attr_writer :connection_pool, :exchange, :exchange_type, :resource_name, :routing_key, :param_key

      # Lee la configuración del Thread actual (usado por el scope .with).
      # @api private
      def thread_config(key)
        Thread.current["bb_#{object_id}_#{key}"]
      end

      # Resuelve la configuración buscando en: 1. Thread (Scope), 2. Clase, 3. Herencia.
      # @api private
      def resolve_config(key, instance_var)
        # 1. Prioridad: Contexto de hilo (.with)
        val = thread_config(key)
        return val if val

        # 2. Prioridad: Jerarquía de clases
        target = self
        while target <= BugBunny::Resource
          value = target.instance_variable_get(instance_var)
          return value.respond_to?(:call) ? value.call : value unless value.nil?
          target = target.superclass
        end
        nil
      end

      # @return [ConnectionPool] El pool de conexiones asignado.
      def connection_pool; resolve_config(:pool, :@connection_pool); end
      
      # @return [String] El exchange configurado.
      # @raise [ArgumentError] Si no se ha definido un exchange.
      def current_exchange; resolve_config(:exchange, :@exchange) || raise(ArgumentError, "Exchange not defined"); end
      
      # @return [String] El tipo de exchange (default: direct).
      def current_exchange_type; resolve_config(:exchange_type, :@exchange_type) || 'direct'; end
      
      # @return [String] El nombre del recurso (ej: 'users'). Se infiere del nombre de la clase si no existe.
      def resource_name
        resolve_config(:resource_name, :@resource_name) || name.demodulize.underscore.pluralize
      end

      # Define la clave raíz para envolver el payload JSON (Wrapping).
      # 
      # Por defecto utiliza `model_name.element`, lo que elimina los namespaces.
      # Ej: `Manager::Service` -> `'service'`.
      #
      # @return [String] La clave paramétrica.
      def param_key
        resolve_config(:param_key, :@param_key) || model_name.element
      end

      # Define un middleware para el cliente HTTP/AMQP de este recurso.
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

      # Instancia un cliente configurado con el pool y middlewares del recurso.
      # @return [BugBunny::Client]
      def bug_bunny_client
        pool = connection_pool
        raise BugBunny::Error, "Connection pool missing for #{name}" unless pool
        
        BugBunny::Client.new(pool: pool) do |conn|
          resolve_middleware_stack.each { |block| block.call(conn) }
        end
      end

      # Ejecuta un bloque (o retorna un Proxy) con una configuración temporal.
      # Útil para cambiar de exchange o routing_key para una operación específica.
      #
      # @example
      #   User.with(routing_key: 'urgent').create(params)
      def with(exchange: nil, routing_key: nil, exchange_type: nil, pool: nil)
        keys = { exchange: "bb_#{object_id}_exchange", exchange_type: "bb_#{object_id}_exchange_type", pool: "bb_#{object_id}_pool", routing_key: "bb_#{object_id}_routing_key" }
        old_values = {}
        keys.each { |k, v| old_values[k] = Thread.current[v] }
        
        # Seteamos valores temporales
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
      
      # Proxy para permitir encadenamiento: User.with(...).find(1)
      class ScopeProxy < BasicObject
        def initialize(target, keys, old_values); @target = target; @keys = keys; @old_values = old_values; end
        def method_missing(method, *args, &block); @target.public_send(method, *args, &block); ensure; @keys.each { |k, v| ::Thread.current[v] = @old_values[k] }; end
      end

      # Calcula la Routing Key.
      # @return [String]
      def calculate_routing_key(id = nil)
        # 1. Contexto .with
        manual_rk = thread_config(:routing_key)
        return manual_rk if manual_rk

        # 2. Configuración estática
        static_rk = resolve_config(:routing_key, :@routing_key)
        return static_rk if static_rk.present?

        # 3. Default: Resource name
        resource_name
      end

      # @!group Acciones CRUD RESTful (Clase)

      # Busca recursos que coincidan con los filtros.
      # Envía: GET resource?query
      def where(filters = {})
        rk = calculate_routing_key
        path = resource_name
        path += "?#{URI.encode_www_form(filters)}" if filters.present?

        response = bug_bunny_client.request(path, method: :get, exchange: current_exchange, exchange_type: current_exchange_type, routing_key: rk)

        return [] unless response['body'].is_a?(Array)
        response['body'].map do |attrs|
          # Al instanciar aquí, se captura el contexto si estamos dentro de un .with
          inst = new(attrs)
          inst.persisted = true
          inst.send(:clear_changes_information)
          inst
        end
      end

      def all; where({}); end

      # Busca un recurso por ID.
      # Envía: GET resource/id
      def find(id)
        rk = calculate_routing_key(id)
        path = "#{resource_name}/#{id}"

        response = bug_bunny_client.request(path, method: :get, exchange: current_exchange, exchange_type: current_exchange_type, routing_key: rk)

        return nil if response.nil? || response['status'] == 404
        
        attributes = response['body']
        return nil unless attributes.is_a?(Hash)

        instance = new(attributes)
        instance.persisted = true
        instance.send(:clear_changes_information)
        instance
      end

      # Crea un nuevo recurso.
      def create(payload)
        instance = new(payload)
        instance.save
        instance
      end
    end

    # @!group Instancia

    # Inicializa una nueva instancia del recurso.
    #
    # **IMPORTANTE:** Captura la configuración del contexto actual (`.with`)
    # y la guarda en la instancia. Esto permite que objetos creados dentro de un bloque `with`
    # mantengan esa configuración (routing_key, exchange) durante todo su ciclo de vida,
    # incluso si `save` se llama fuera del bloque.
    #
    # @param attributes [Hash] Atributos iniciales.
    def initialize(attributes = {})
      @remote_attributes = {}.with_indifferent_access
      @persisted = false
      
      # === CAPTURA DE CONTEXTO ===
      @routing_key = self.class.thread_config(:routing_key)
      @exchange = self.class.thread_config(:exchange)
      @exchange_type = self.class.thread_config(:exchange_type)
      
      assign_attributes(attributes)
      super()
    end

    # Prioridad Routing Key: 1. Instancia (Capturada), 2. Clase
    def calculate_routing_key(id=nil)
      return @routing_key if @routing_key
      self.class.calculate_routing_key(id)
    end

    # Prioridad Exchange: 1. Instancia (Capturada), 2. Clase
    def current_exchange
      @exchange || self.class.current_exchange
    end

    # Prioridad Exchange Type: 1. Instancia (Capturada), 2. Clase
    def current_exchange_type
      @exchange_type || self.class.current_exchange_type
    end

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

    # Retorna solo los atributos que han cambiado.
    def changes_to_send
      return changes.transform_values(&:last) unless changes.empty?
      @remote_attributes.except('id', 'ID', 'Id', '_id')
    end

    # Métodos mágicos para atributos.
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

    # Guarda el registro.
    # Envía POST si es nuevo, PUT si ya existe.
    #
    # **AUTOMÁTICO:** Envuelve los parámetros en la clave del modelo (`param_key`).
    # Ej: Manager::Service -> "service". Esto facilita `params.require(:service)`.
    #
    # @return [Boolean] true si se guardó correctamente.
    def save
      return false unless valid?

      run_callbacks(:save) do
        is_new = !persisted?
        rk = calculate_routing_key(id)
        
        # 1. Obtenemos el payload plano (atributos modificados)
        flat_payload = changes_to_send
        
        # 2. Wrappeamos automáticamente en la clave del modelo
        key = self.class.param_key
        wrapped_payload = { key => flat_payload }

        # Mapeo a verbos HTTP
        if is_new
          # REST: POST resource (Create)
          path = self.class.resource_name
          response = bug_bunny_client.request(path, method: :post, exchange: current_exchange, exchange_type: current_exchange_type, routing_key: rk, body: wrapped_payload)
        else
          # REST: PUT resource/id (Update)
          path = "#{self.class.resource_name}/#{id}"
          response = bug_bunny_client.request(path, method: :put, exchange: current_exchange, exchange_type: current_exchange_type, routing_key: rk, body: wrapped_payload)
        end

        handle_save_response(response)
      end
    rescue BugBunny::UnprocessableEntity => e
      load_remote_rabbit_errors(e.error_messages)
      false
    end

    # Elimina el registro.
    # Envía DELETE resource/id.
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
