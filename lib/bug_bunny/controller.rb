# frozen_string_literal: true

require 'active_model'
require 'rack'
require 'active_support/core_ext/class/attribute'

module BugBunny
  # Clase base para todos los Controladores de Mensajes en BugBunny.
  #
  # @author Gabriel
  # @since 3.0.6
  class Controller
    include ActiveModel::Model
    include ActiveModel::Attributes

    # @return [Hash] Metadatos del mensaje entrante.
    attribute :headers

    # @return [ActiveSupport::HashWithIndifferentAccess] Parámetros unificados.
    attribute :params

    # @return [String] Cuerpo crudo.
    attribute :raw_string

    # @return [Hash] Headers de respuesta.
    attr_reader :response_headers

    # @return [Hash, nil] Respuesta renderizada.
    attr_reader :rendered_response

    # --- INFRAESTRUCTURA DE FILTROS (DEFINICIÓN) ---
    # Deben definirse ANTES de ser usados por la configuración de logs.

    # @api private
    def self.before_actions
      @before_actions ||= Hash.new { |h, k| h[k] = [] }
    end

    # @api private
    def self.around_actions
      @around_actions ||= Hash.new { |h, k| h[k] = [] }
    end

    # Registra un filtro que se ejecutará **antes** de la acción.
    def self.before_action(method_name, **options)
      register_callback(before_actions, method_name, options)
    end

    # Registra un filtro que **envuelve** la ejecución de la acción.
    def self.around_action(method_name, **options)
      register_callback(around_actions, method_name, options)
    end

    # Helper interno para registrar callbacks.
    def self.register_callback(collection, method_name, options)
      only = Array(options[:only]).map(&:to_sym)
      target_actions = only.empty? ? [:_all_actions] : only
      target_actions.each { |action| collection[action] << method_name }
    end

    # --- CONFIGURACIÓN DE LOGGING ---

    # Define los tags que se antepondrán a cada línea de log.
    class_attribute :log_tags
    self.log_tags = []

    # AHORA SÍ: Podemos llamar a around_action porque ya fue definido arriba.
    around_action :apply_log_tags

    # --- INICIALIZACIÓN ---

    def initialize(attributes = {})
      super
      @response_headers = {}
    end

    # --- MANEJO DE ERRORES ---

    # @api private
    def self.rescue_handlers
      @rescue_handlers ||= []
    end

    def self.rescue_from(*klasses, with: nil, &block)
      handler = with || block
      raise ArgumentError, "Need a handler. Supply 'with: :method' or a block." unless handler

      klasses.each do |klass|
        rescue_handlers.unshift([klass, handler])
      end
    end

    # --- PIPELINE DE EJECUCIÓN ---

    def self.call(headers:, body: {})
      new(headers: headers).process(body)
    end

    def process(body)
      prepare_params(body)

      # Inyección de configuración global de logs si no hay específica
      if self.class.log_tags.empty? && BugBunny.configuration.log_tags.any?
        self.class.log_tags = BugBunny.configuration.log_tags
      end

      action_name = headers[:action].to_sym
      current_arounds = resolve_callbacks(self.class.around_actions, action_name)

      # Definir el núcleo de ejecución
      core_execution = lambda do
        return unless run_before_actions(action_name)

        if respond_to?(action_name)
          public_send(action_name)
        else
          raise NameError, "Action '#{action_name}' not found in #{self.class.name}"
        end
      end

      # Construir la cadena de responsabilidad
      execution_chain = current_arounds.reverse.inject(core_execution) do |next_step, method_name|
        lambda { send(method_name, &next_step) }
      end

      # Ejecutar la cadena
      execution_chain.call

      # Respuesta final
      rendered_response || { status: 204, headers: response_headers, body: nil }

    rescue StandardError => e
      handle_exception(e)
    end

    private

    # --- HELPERS INTERNOS ---

    def resolve_callbacks(collection, action_name)
      (collection[:_all_actions] || []) + (collection[action_name] || [])
    end

    def run_before_actions(action_name)
      current_befores = resolve_callbacks(self.class.before_actions, action_name)
      current_befores.uniq.each do |method_name|
        send(method_name)
        return false if rendered_response
      end
      true
    end

    def handle_exception(exception)
      handler_entry = self.class.rescue_handlers.find do |klass, _|
        if klass.is_a?(String)
          exception.class.name == klass
        else
          exception.is_a?(klass)
        end
      end

      if handler_entry
        _, handler = handler_entry
        if handler.is_a?(Symbol); send(handler, exception)
        elsif handler.respond_to?(:call); instance_exec(exception, &handler)
        end
        return rendered_response if rendered_response
      end

      BugBunny.configuration.logger.error("Controller Error (#{exception.class}): #{exception.message}")
      BugBunny.configuration.logger.error(exception.backtrace.join("\n"))

      {
        status: 500,
        headers: response_headers,
        body: { error: exception.message, type: exception.class.name }
      }
    end

    def render(status:, json: nil)
      code = Rack::Utils::SYMBOL_TO_STATUS_CODE[status] || 200
      @rendered_response = {
        status: code,
        headers: response_headers,
        body: json
      }
    end

    def prepare_params(body)
      self.params = {}.with_indifferent_access
      params.merge!(headers[:query_params]) if headers[:query_params].present?
      params[:id] = headers[:id] if headers[:id].present?

      if body.is_a?(Hash)
        params.merge!(body)
      elsif body.is_a?(String) && headers[:content_type].to_s.include?('json')
        parsed = JSON.parse(body) rescue nil
        params.merge!(parsed) if parsed
      else
        self.raw_string = body
      end
    end

    # --- LÓGICA DE LOGGING ENCAPSULADA ---

    def apply_log_tags
      tags = compute_tags
      if defined?(Rails) && Rails.logger.respond_to?(:tagged) && tags.any?
        Rails.logger.tagged(*tags) { yield }
      else
        yield
      end
    end

    def compute_tags
      self.class.log_tags.map do |tag|
        case tag
        when Proc
          tag.call(self)
        when Symbol
          respond_to?(tag, true) ? send(tag) : tag
        else
          tag
        end
      end.compact
    end

    def uuid
      headers[:correlation_id] || headers['X-Request-Id']
    end
  end
end
