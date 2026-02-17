# frozen_string_literal: true

require 'active_model'
require 'rack'

module BugBunny
  # Clase base para Controladores de Mensajes.
  #
  # Provee una abstracción similar a ActionController para manejar peticiones RPC.
  # Incluye soporte para `before_action`, manejo de excepciones declarativo (`rescue_from`),
  # normalización de parámetros y manipulación de headers de respuesta.
  #
  # @author Gabriel
  # @since 3.0.6
  class Controller
    include ActiveModel::Model
    include ActiveModel::Attributes

    # @return [Hash] Metadatos del mensaje entrante (headers AMQP, routing info).
    attribute :headers

    # @return [ActiveSupport::HashWithIndifferentAccess] Parámetros unificados (Body + Query + Route).
    attribute :params

    # @return [String] Cuerpo crudo si el payload no es JSON.
    attribute :raw_string

    # @return [Hash] Headers que se enviarán en la respuesta.
    attr_reader :response_headers

    # @return [Hash, nil] La respuesta renderizada final { status, headers, body }.
    attr_reader :rendered_response

    # Inicializa el controlador.
    def initialize(attributes = {})
      super
      @response_headers = {}
    end

    # --- INFRAESTRUCTURA DE FILTROS (Before Actions) ---

    # @api private
    def self.before_actions
      @before_actions ||= Hash.new { |h, k| h[k] = [] }
    end

    # Registra un callback que se ejecutará antes de las acciones.
    # @example
    #   before_action :authenticate
    def self.before_action(method_name, **options)
      only = Array(options[:only]).map(&:to_sym)
      target_actions = only.empty? ? [:_all_actions] : only

      target_actions.each do |action|
        before_actions[action] << method_name
      end
    end

    # --- INFRAESTRUCTURA DE MANEJO DE ERRORES (Rescue From) ---

    # @api private
    def self.rescue_handlers
      @rescue_handlers ||= []
    end

    # Registra un manejador para una o más excepciones.
    # @example
    #   rescue_from User::Unauthorized, with: :deny_access
    def self.rescue_from(*klasses, with: nil, &block)
      handler = with || block
      raise ArgumentError, "Need a handler. Supply 'with: :method' or a block." unless handler

      klasses.each do |klass|
        rescue_handlers.unshift([klass, handler])
      end
    end

    # --- PIPELINE DE EJECUCIÓN ---

    # Punto de entrada principal llamado por el Consumer.
    # @return [Hash] La respuesta final { status, headers, body }.
    def self.call(headers:, body: {})
      new(headers: headers).process(body)
    end

    # Ejecuta el ciclo de vida de la petición: Params -> Filtros -> Acción.
    def process(body)
      prepare_params(body)
      action_name = headers[:action].to_sym

      # 1. Ejecutar Before Actions
      return rendered_response unless run_before_actions(action_name)

      # 2. Ejecutar Acción
      if respond_to?(action_name)
        public_send(action_name)
      else
        raise NameError, "Action '#{action_name}' not found in #{self.class.name}"
      end

      # 3. Respuesta por defecto (204 No Content) si no hubo render explícito
      rendered_response || { status: 204, headers: response_headers, body: nil }

    rescue StandardError => e
      handle_exception(e)
    end

    private

    def handle_exception(exception)
      handler_entry = self.class.rescue_handlers.find { |klass, _| exception.is_a?(klass) }

      if handler_entry
        _, handler = handler_entry
        if handler.is_a?(Symbol)
          send(handler, exception)
        elsif handler.respond_to?(:call)
          instance_exec(exception, &handler)
        end
        return rendered_response if rendered_response
      end

      # Fallback por defecto (500)
      BugBunny.configuration.logger.error("Controller Error (#{exception.class}): #{exception.message}")
      BugBunny.configuration.logger.error(exception.backtrace.join("\n"))

      { status: 500, headers: response_headers, body: { error: exception.message, type: exception.class.name } }
    end

    def run_before_actions(action_name)
      chain = (self.class.before_actions[:_all_actions] || []) +
              (self.class.before_actions[action_name] || [])

      chain.uniq.each do |method_name|
        send(method_name)
        return false if rendered_response
      end
      true
    end

    # Construye la respuesta RPC normalizada.
    #
    # @param status [Symbol, Integer] Código HTTP (ej: :ok, 200).
    # @param json [Object] Objeto a serializar en el body.
    def render(status:, json: nil)
      code = Rack::Utils::SYMBOL_TO_STATUS_CODE[status] || 200

      # Inyectamos los headers definidos por el usuario en la respuesta
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
  end
end
