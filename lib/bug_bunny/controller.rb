require 'active_model'
require 'rack'

module BugBunny
  # Clase base para los controladores de mensajes.
  #
  # Imita el comportamiento de `ActionController` en Rails, permitiendo definir acciones,
  # callbacks (`before_action`) y renderizar respuestas JSON.
  #
  # @example Definición de un controlador
  #   class UsersController < BugBunny::Controller
  #     before_action :set_user, only: [:show]
  #
  #     def show
  #       render status: :ok, json: @user
  #     end
  #
  #     private
  #
  #     def set_user
  #       @user = User.find(params[:id])
  #     end
  #   end
  class Controller
    include ActiveModel::Model
    include ActiveModel::Attributes

    # @return [Hash] Metadatos del mensaje (headers, routing key, action, id).
    attribute :headers

    # @return [ActiveSupport::HashWithIndifferentAccess] Parámetros combinados (ID + Body).
    attribute :params

    # @return [String, nil] El cuerpo crudo del mensaje si no pudo ser parseado como Hash.
    attribute :raw_string

    # @return [Hash, nil] La respuesta renderizada ({ status: ..., body: ... }).
    attr_reader :rendered_response

    # @return [Hash] Almacén de callbacks configurados por acción.
    # @api private
    def self.before_actions
      @before_actions ||= Hash.new { |hash, key| hash[key] = [] }
    end

    # Registra un callback para ejecutarse antes de la acción principal.
    #
    # @param method_name [Symbol] Nombre del método a ejecutar.
    # @param options [Hash] Opciones de filtrado.
    # @option options [Array<Symbol>, Symbol] :only Ejecutar solo en estas acciones.
    def self.before_action(method_name, **options)
      actions = options.delete(:only) || []
      target = actions.empty? ? :_all_actions : actions
      Array(target).each do |action|
        key = action == :_all_actions ? :_all_actions : action.to_sym
        before_actions[key] << method_name
      end
    end

    # Punto de entrada principal. Instancia el controlador y ejecuta la acción.
    #
    # 1. Instancia el controlador.
    # 2. Prepara los parámetros (`prepare_params`).
    # 3. Ejecuta los callbacks (`before_action`).
    # 4. Invoca el método de la acción.
    # 5. Retorna la respuesta renderizada.
    #
    # @param headers [Hash] Metadatos del mensaje.
    # @param body [Hash, String] Payload del mensaje.
    # @return [Hash] Respuesta final { status: Integer, body: Object }.
    def self.call(headers:, body: {})
      controller = new(headers: headers)
      controller.prepare_params(body)

      # Si un callback renderiza algo, detenemos la ejecución (halt)
      return controller.rendered_response unless controller.run_callbacks

      action_method = controller.headers[:action].to_sym
      if controller.respond_to?(action_method)
        controller.send(action_method)
      else
        raise NameError, "Action '#{action_method}' not found"
      end

      # Si no se renderizó nada explícitamente, retornamos 204 No Content
      controller.rendered_response || { status: 204, body: nil }
    rescue StandardError => e
      rescue_from(e)
    end

    # Renderiza la respuesta que será enviada de vuelta al cliente RPC.
    #
    # @param status [Symbol, Integer] Código de estado HTTP (ej: :ok, :created, 404).
    # @param json [Object] Objeto a serializar como cuerpo de la respuesta.
    # @return [Hash] La estructura de respuesta interna.
    def render(status:, json: nil)
      code = Rack::Utils::SYMBOL_TO_STATUS_CODE[status] || 200
      @rendered_response = { status: code, body: json }
    end

    # Normaliza y mezcla los parámetros entrantes.
    #
    # Combina el `id` (extraído de headers o ruta) con el cuerpo del mensaje.
    # Si el cuerpo es JSON String, intenta parsearlo.
    #
    # @param body [Hash, String] El cuerpo del mensaje.
    # @return [void]
    def prepare_params(body)
      self.params ||= {}.with_indifferent_access
      params[:id] = headers[:id] if headers[:id].present?

      if body.is_a?(Hash)
        params.merge!(body)
      elsif body.is_a?(String) && headers[:content_type] =~ /json/
        params.merge!(JSON.parse(body)) rescue nil
      else
        self.raw_string = body
      end
    end

    # Ejecuta la cadena de callbacks.
    #
    # @return [Boolean] true si todos los callbacks pasaron, false si alguno renderizó (halt).
    # @api private
    def run_callbacks
      current = headers[:action].to_sym
      chain = self.class.before_actions[:_all_actions] + self.class.before_actions[current]
      chain.each do |method|
        send(method)
        return false if @rendered_response
      end
      true
    end

    # Maneja excepciones no capturadas durante la ejecución de la acción.
    #
    # @param e [Exception] La excepción capturada.
    # @return [Hash] Respuesta de error 500.
    def self.rescue_from(e)
      BugBunny.configuration.logger.error("Controller: #{e.message}")
      { status: 500, error: e.message }
    end
  end
end
