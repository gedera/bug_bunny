# lib/bug_bunny/controller.rb
require 'active_model'
require 'rack'

module BugBunny
  # Clase base para Controladores de Mensajes.
  #
  # Provee una abstracción similar a ActionController para manejar peticiones RPC.
  # Incluye soporte para `before_action`, manejo de excepciones declarativo (`rescue_from`)
  # y normalización de parámetros.
  class Controller
    include ActiveModel::Model
    include ActiveModel::Attributes

    # @return [Hash] Metadatos del mensaje (headers AMQP, routing info).
    attribute :headers

    # @return [ActiveSupport::HashWithIndifferentAccess] Parámetros unificados (Body + Query + Route).
    attribute :params

    # @return [String] Cuerpo crudo si el payload no es JSON.
    attribute :raw_string

    # @return [Hash, nil] La respuesta renderizada { status, body }.
    attr_reader :rendered_response

    # --- INFRAESTRUCTURA DE FILTROS (Before Actions) ---

    # @api private
    def self.before_actions
      @before_actions ||= Hash.new { |h, k| h[k] = [] }
    end

    # Registra un callback que se ejecutará antes de las acciones.
    #
    # @param method_name [Symbol] Nombre del método a ejecutar.
    # @param options [Hash] Opciones de filtro (:only).
    # @example
    #   before_action :set_user, only: [:show, :update]
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
    # Los manejadores se evalúan en orden inverso (el último registrado tiene prioridad).
    #
    # @param klasses [Class] Clases de excepción a capturar.
    # @param with [Symbol] Nombre del método manejador.
    # @param block [Proc] Bloque manejador.
    #
    # @example Con método
    #   rescue_from User::NotAuthorized, with: :deny_access
    #
    # @example Con bloque
    #   rescue_from ActiveRecord::RecordNotFound do |e|
    #     render status: :not_found, json: { error: e.message }
    #   end
    def self.rescue_from(*klasses, with: nil, &block)
      handler = with || block
      raise ArgumentError, "Need a handler. Supply 'with: :method' or a block." unless handler

      klasses.each do |klass|
        # Insertamos al principio para que las últimas definiciones tengan prioridad (LIFO)
        rescue_handlers.unshift([klass, handler])
      end
    end

    # --- PIPELINE DE EJECUCIÓN ---

    # Punto de entrada principal llamado por el Consumer.
    # Instancia el controlador y procesa el mensaje.
    #
    # @param headers [Hash] Metadatos del mensaje.
    # @param body [Hash, String] Payload deserializado.
    # @return [Hash] La respuesta final { status, body }.
    def self.call(headers:, body: {})
      new(headers: headers).process(body)
    end

    # Ejecuta el ciclo de vida de la petición: Params -> Filtros -> Acción.
    # Captura cualquier error y delega al sistema `rescue_from`.
    #
    # @param body [Hash, String] Payload.
    # @return [Hash] Respuesta RPC.
    def process(body)
      prepare_params(body)
      action_name = headers[:action].to_sym

      # 1. Ejecutar Before Actions (si retorna false, hubo render/halt)
      return rendered_response unless run_before_actions(action_name)

      # 2. Ejecutar Acción
      if respond_to?(action_name)
        public_send(action_name)
      else
        raise NameError, "Action '#{action_name}' not found in #{self.class.name}"
      end

      # 3. Respuesta por defecto (204 No Content) si la acción no llamó a render
      rendered_response || { status: 204, body: nil }

    rescue StandardError => e
      handle_exception(e)
    end

    private

    # Busca un manejador registrado para la excepción y lo ejecuta.
    # Si no hay ninguno, loguea y devuelve 500.
    def handle_exception(exception)
      # Buscamos el primer handler compatible con la clase del error
      handler_entry = self.class.rescue_handlers.find { |klass, _| exception.is_a?(klass) }

      if handler_entry
        _, handler = handler_entry

        # Ejecutamos el handler en el contexto de la INSTANCIA
        if handler.is_a?(Symbol)
          send(handler, exception)
        elsif handler.respond_to?(:call)
          instance_exec(exception, &handler)
        end

        # Si el handler hizo render, retornamos esa respuesta
        return rendered_response if rendered_response
      end

      # === FALLBACK POR DEFECTO ===
      # Si el error no fue rescatado por el usuario, actuamos como red de seguridad.
      BugBunny.configuration.logger.error("Controller Error (#{exception.class}): #{exception.message}")
      BugBunny.configuration.logger.error(exception.backtrace.join("\n"))

      { status: 500, body: { error: exception.message, type: exception.class.name } }
    end

    # Ejecuta la cadena de filtros before_action.
    def run_before_actions(action_name)
      chain = (self.class.before_actions[:_all_actions] || []) +
              (self.class.before_actions[action_name] || [])

      chain.uniq.each do |method_name|
        send(method_name)
        # Si un filtro llamó a 'render', detenemos la cadena (halt)
        return false if rendered_response
      end
      true
    end

    # Construye la respuesta RPC normalizada.
    #
    # @param status [Symbol, Integer] Código HTTP (ej: :ok, 200, :not_found).
    # @param json [Object] Objeto a serializar en el body.
    def render(status:, json: nil)
      code = Rack::Utils::SYMBOL_TO_STATUS_CODE[status] || 200
      @rendered_response = { status: code, body: json }
    end

    # Normaliza y fusiona parámetros de múltiples fuentes.
    # Prioridad: Body > ID Ruta > Query Params.
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
