# frozen_string_literal: true

require 'active_model'
require 'rack'
require 'active_support/core_ext/class/attribute'

module BugBunny
  # Clase base para todos los Controladores de Mensajes en BugBunny.
  #
  # Actúa como el receptor final de los mensajes enrutados desde el consumidor.
  # Implementa un ciclo de vida similar a ActionController en Rails, soportando:
  # - Filtros (`before_action`, `around_action`).
  # - Manejo declarativo de errores (`rescue_from`).
  # - Parsing de parámetros unificados (`params`).
  # - Respuestas estructuradas (`render`).
  #
  # @author Gabriel
  # @since 3.0.6
  class Controller
    include ActiveModel::Model
    include ActiveModel::Attributes

    # @!group Atributos de Instancia

    # @return [Hash] Metadatos del mensaje entrante (ej. HTTP method, routing_key, id).
    attribute :headers

    # @return [ActiveSupport::HashWithIndifferentAccess] Parámetros unificados (Body JSON + Query String).
    attribute :params

    # @return [String] Cuerpo crudo original en caso de no ser JSON.
    attribute :raw_string

    # @return [Hash] Headers de respuesta que serán enviados de vuelta en RPC.
    attr_reader :response_headers

    # @return [Hash, nil] Respuesta final renderizada.
    attr_reader :rendered_response

    # @!endgroup


    # ==========================================
    # INFRAESTRUCTURA DE FILTROS Y LOGS (HEREDABLES)
    # ==========================================

    # Usamos `class_attribute` con `default` para garantizar la herencia correcta
    # hacia las subclases (ej. de ApplicationController a ServicesController).
    class_attribute :before_actions, default: {}
    class_attribute :around_actions, default: {}
    class_attribute :log_tags, default: []
    class_attribute :rescue_handlers, default: []

    # Registra un filtro que se ejecutará **antes** de la acción.
    # Si el filtro invoca `render`, la cadena se interrumpe y la acción no se ejecuta.
    #
    # @param method_name [Symbol] Nombre del método privado a ejecutar.
    # @param options [Hash] Opciones como `only: [:show, :update]`.
    # @return [void]
    def self.before_action(method_name, **options)
      register_callback(:before_actions, method_name, options)
    end

    # Registra un filtro que **envuelve** la ejecución de la acción.
    # El método registrado debe invocar `yield` para continuar la ejecución.
    #
    # @param method_name [Symbol] Nombre del método privado a ejecutar.
    # @param options [Hash] Opciones como `only: [:index]`.
    # @return [void]
    def self.around_action(method_name, **options)
      register_callback(:around_actions, method_name, options)
    end

    # Manejo declarativo de excepciones.
    # Atrapa errores específicos que ocurran durante la ejecución de la acción.
    #
    # @example
    #   rescue_from Api::Error::NotFound, with: :render_not_found
    #   rescue_from StandardError do |e|
    #     render status: 500, json: { error: e.message }
    #   end
    #
    # @param klasses [Array<Class, String>] Clases de excepciones a atrapar.
    # @param with [Symbol, nil] Nombre del método manejador.
    # @yield [Exception] Bloque opcional para manejar el error inline.
    # @raise [ArgumentError] Si no se provee un manejador (with o block).
    def self.rescue_from(*klasses, with: nil, &block)
      handler = with || block
      raise ArgumentError, "Need a handler. Supply 'with: :method' or a block." unless handler

      # Duplicamos el array del padre para no mutarlo al registrar reglas en el hijo
      new_handlers = self.rescue_handlers.dup

      klasses.each do |klass|
        new_handlers.unshift([klass, handler])
      end

      self.rescue_handlers = new_handlers
    end

    # Helper interno para registrar callbacks garantizando Thread-Safety e Inmutabilidad del padre.
    # @api private
    def self.register_callback(collection_name, method_name, options)
      current_hash = send(collection_name)

      # Deep dup: Clonamos el hash y sus arrays internos para no modificar la clase padre
      new_hash = current_hash.transform_values(&:dup)

      only = Array(options[:only]).map(&:to_sym)
      target_actions = only.empty? ? [:_all_actions] : only

      target_actions.each do |action|
        new_hash[action] ||= []
        new_hash[action] << method_name
      end

      send("#{collection_name}=", new_hash)
    end

    # Aplicamos automáticamente las etiquetas de logs a todas las acciones.
    around_action :apply_log_tags


    # ==========================================
    # INICIALIZACIÓN Y CICLO DE VIDA
    # ==========================================

    def initialize(attributes = {})
      super
      @response_headers = {}
    end

    # Punto de entrada principal estático llamado por el Router (`BugBunny::Consumer`).
    #
    # @param headers [Hash] Metadatos y variables de enrutamiento.
    # @param body [String, Hash] El payload del mensaje AMQP.
    # @return [Hash] Respuesta final estructurada.
    def self.call(headers:, body: {})
      new(headers: headers).process(body)
    end

    # Ejecuta el ciclo de vida completo de la petición: Params -> Before -> Action -> Rescue.
    #
    # @param body [String, Hash] El cuerpo del mensaje.
    # @return [Hash] La respuesta lista para ser enviada vía RabbitMQ RPC.
    def process(body)
      prepare_params(body)

      # Inyección de configuración global de logs si el controlador no define propios
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

      # Construir e invocar la cadena de responsabilidad (Middlewares/Around Actions)
      execution_chain = current_arounds.reverse.inject(core_execution) do |next_step, method_name|
        lambda { send(method_name, &next_step) }
      end

      execution_chain.call

      # Si no hubo renderización explícita, devuelve 204 No Content
      rendered_response || { status: 204, headers: response_headers, body: nil }

    rescue StandardError => e
      handle_exception(e)
    end

    private

    # ==========================================
    # HELPERS INTERNOS
    # ==========================================

    # Evalúa la excepción lanzada y busca el manejador más adecuado definido en `rescue_from`.
    #
    # @param exception [StandardError] La excepción atrapada.
    # @return [Hash] Respuesta de error renderizada.
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
        if handler.is_a?(Symbol)
          send(handler, exception)
        elsif handler.respond_to?(:call)
          instance_exec(exception, &handler)
        end
        return rendered_response if rendered_response
      end

      # Fallback genérico si la excepción no fue mapeada
      BugBunny.configuration.logger.error("[BugBunny::Controller] 💥 Unhandled Exception (#{exception.class}): #{exception.message}")
      BugBunny.configuration.logger.error(exception.backtrace.first(5).join("\n"))

      {
        status: 500,
        headers: response_headers,
        body: { error: "Internal Server Error", detail: exception.message, type: exception.class.name }
      }
    end

    # Renderiza una respuesta que será enviada de vuelta por la cola reply-to.
    #
    # @param status [Symbol, Integer] Código HTTP (ej. :ok, :not_found, 201).
    # @param json [Object] El payload a serializar como JSON.
    # @return [Hash] La estructura renderizada interna.
    def render(status:, json: nil)
      code = Rack::Utils::SYMBOL_TO_STATUS_CODE[status] || status.to_i
      code = 200 if code.zero? # Fallback de seguridad

      @rendered_response = {
        status: code,
        headers: response_headers,
        body: json
      }
    end

    # Unifica el query string, parámetros de ruta y el body JSON en un solo objeto `params`.
    def prepare_params(body)
      self.params = {}.with_indifferent_access

      params.merge!(headers[:query_params]) if headers[:query_params].present?
      params[:id] = headers[:id] if headers[:id].present?

      if body.is_a?(Hash)
        params.merge!(body)
      elsif body.is_a?(String) && headers[:content_type].to_s.include?('json')
        parsed = begin
                   JSON.parse(body)
                 rescue JSON::ParserError
                   nil
                 end
        params.merge!(parsed) if parsed
      else
        self.raw_string = body
      end
    end

    # Obtiene la lista combinada de callbacks globales y específicos para una acción.
    def resolve_callbacks(collection, action_name)
      (collection[:_all_actions] || []) + (collection[action_name] || [])
    end

    # Ejecuta secuencialmente todos los before_actions.
    # Si alguno invoca render(), detiene el flujo devolviendo `false`.
    def run_before_actions(action_name)
      current_befores = resolve_callbacks(self.class.before_actions, action_name)
      current_befores.uniq.each do |method_name|
        send(method_name)
        return false if rendered_response
      end
      true
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

    # @return [String] Identificador único de trazabilidad de la petición.
    def uuid
      headers[:correlation_id] || headers['X-Request-Id']
    end
  end
end
