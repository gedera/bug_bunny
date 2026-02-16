# frozen_string_literal: true

require 'active_model'
require 'active_support/core_ext/string/inflections'
require 'uri'

# Requires de los submódulos
require_relative 'resource/configuration'
require_relative 'resource/querying'
require_relative 'resource/persistence'
require_relative 'resource/scope_proxy'

module BugBunny
  # Clase base para modelos remotos que implementan el patrón **Active Record over AMQP**.
  #
  # Permite interactuar con servicios remotos como si fueran modelos locales,
  # gestionando la serialización, validación y transporte RPC automáticamente.
  #
  # @example Definición
  #   class User < BugBunny::Resource
  #     self.resource_name = 'users'
  #   end
  class Resource
    include ActiveModel::API
    include ActiveModel::Dirty
    include ActiveModel::Validations
    extend ActiveModel::Callbacks

    # Inclusión de módulos funcionales
    extend Configuration
    extend Querying
    include Persistence

    define_model_callbacks :save, :create, :update, :destroy

    # @return [HashWithIndifferentAccess] Atributos remotos.
    attr_reader :remote_attributes

    # @return [Boolean] Estado de persistencia.
    attr_accessor :persisted

    # @return [String] Configuración de instancia.
    attr_accessor :routing_key, :exchange, :exchange_type

    # Inicializa una nueva instancia.
    # Captura el contexto del thread actual para mantener la consistencia del enrutamiento.
    # @param attributes [Hash] Atributos iniciales.
    def initialize(attributes = {})
      @remote_attributes = {}.with_indifferent_access
      @persisted = false
      capture_thread_context
      assign_attributes(attributes)
      super()
    end

    # Captura la configuración del thread (usada por .with) en la instancia.
    # @api private
    def capture_thread_context
      @routing_key = self.class.thread_config(:routing_key)
      @exchange = self.class.thread_config(:exchange)
      @exchange_type = self.class.thread_config(:exchange_type)
    end

    # @return [String] Routing Key calculada.
    def calculate_routing_key(identifier = nil)
      @routing_key || self.class.calculate_routing_key(identifier)
    end

    # @return [String] Exchange actual.
    def current_exchange
      @exchange || self.class.current_exchange
    end

    # @return [String] Tipo de Exchange actual.
    def current_exchange_type
      @exchange_type || self.class.current_exchange_type
    end

    # @return [BugBunny::Client] Cliente HTTP/AMQP asociado.
    def bug_bunny_client
      self.class.bug_bunny_client
    end

    # @return [Boolean] true si el objeto ya existe remotamente.
    def persisted?
      !!@persisted
    end

    # Asigna atributos en masa.
    # @param new_attributes [Hash] Nuevos valores.
    def assign_attributes(new_attributes)
      return if new_attributes.nil?

      new_attributes.each { |k, v| public_send("#{k}=", v) }
    end

    # Actualiza atributos y guarda el registro.
    # @param attributes [Hash] Nuevos valores.
    # @return [Boolean] true si se guardó correctamente.
    def update(attributes)
      assign_attributes(attributes)
      save
    end

    # @return [Hash] Mapa de cambios a enviar al servidor.
    def changes_to_send
      return changes.transform_values(&:last) unless changes.empty?

      @remote_attributes.except('id', 'ID', 'Id', '_id')
    end

    # Maneja getters y setters dinámicos.
    def method_missing(method_name, *args, &block)
      if method_name.to_s.end_with?('=')
        handle_setter(method_name, args.first)
      elsif @remote_attributes.key?(method_name.to_s)
        @remote_attributes[method_name.to_s]
      else
        super
      end
    end

    # Cumple contrato de Ruby para métodos dinámicos.
    def respond_to_missing?(method_name, include_private = false)
      @remote_attributes.key?(method_name.to_s.sub(/=$/, '')) || super
    end

    # @return [Object] ID del recurso.
    def id
      @remote_attributes['id'] || @remote_attributes['ID'] || @remote_attributes['_id']
    end

    def id=(value)
      @remote_attributes['id'] = value
    end

    # Helper para validaciones de ActiveModel.
    def read_attribute_for_validation(attr)
      @remote_attributes[attr.to_s]
    end

    private

    def handle_setter(method_name, val)
      key = method_name.to_s.chop
      attribute_will_change!(key) unless @remote_attributes[key] == val
      @remote_attributes[key] = val
    end
  end
end
