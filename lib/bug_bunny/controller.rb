# lib/bug_bunny/controller.rb
require 'active_model'
require 'rack'

module BugBunny
  # Clase base para Controladores de Mensajes.
  #
  # Provee una abstracción similar a ActionController para manejar peticiones RPC.
  # Unifica el acceso a parámetros (`params`) independientemente de si vinieron
  # en el cuerpo del mensaje, en la URL (query string) o en la ruta (ID).
  class Controller
    include ActiveModel::Model
    include ActiveModel::Attributes

    # @return [Hash] Metadatos completos (headers, query_params, route info).
    attribute :headers

    # @return [ActiveSupport::HashWithIndifferentAccess] Parámetros unificados.
    attribute :params

    # @return [String] Cuerpo crudo si no es JSON.
    attribute :raw_string

    # @return [Hash] Respuesta renderizada.
    attr_reader :rendered_response

    # @api private
    def self.before_actions
      @before_actions ||= Hash.new { |hash, key| hash[key] = [] }
    end

    # Registra un callback before_action.
    def self.before_action(method_name, **options)
      actions = options.delete(:only) || []
      target = actions.empty? ? :_all_actions : actions
      Array(target).each do |action|
        key = action == :_all_actions ? :_all_actions : action.to_sym
        before_actions[key] << method_name
      end
    end

    # Pipeline de ejecución principal.
    # @param headers [Hash] Metadatos parseados por el Consumer.
    # @param body [String, Hash] Payload.
    def self.call(headers:, body: {})
      controller = new(headers: headers)
      controller.prepare_params(body)

      return controller.rendered_response unless controller.run_callbacks

      action_method = controller.headers[:action].to_sym
      if controller.respond_to?(action_method)
        controller.send(action_method)
      else
        raise NameError, "Action '#{action_method}' not found in #{name}"
      end

      controller.rendered_response || { status: 204, body: nil }
    rescue StandardError => e
      rescue_from(e)
    end

    # Construye la respuesta RPC.
    # @param status [Symbol, Integer] Código HTTP equivalente (ej: :ok, 422).
    # @param json [Object] Objeto a devolver.
    def render(status:, json: nil)
      code = Rack::Utils::SYMBOL_TO_STATUS_CODE[status] || 200
      @rendered_response = { status: code, body: json }
    end

    # Unifica parámetros de múltiples fuentes en `params`.
    # Prioridad: Body > ID Ruta > Query Params.
    #
    # @param body [Hash, String] Payload.
    def prepare_params(body)
      self.params ||= {}.with_indifferent_access

      # 1. Query Params (de la URL ?active=true)
      if headers[:query_params].present?
        params.merge!(headers[:query_params])
      end

      # 2. ID explícito de ruta (/users/show/12)
      params[:id] = headers[:id] if headers[:id].present?

      # 3. Payload Body (JSON)
      if body.is_a?(Hash)
        params.merge!(body)
      elsif body.is_a?(String) && headers[:content_type] =~ /json/
        parsed = JSON.parse(body) rescue nil
        params.merge!(parsed) if parsed
      else
        self.raw_string = body
      end
    end

    # Ejecuta callbacks. Retorna false si hubo `render` (halt).
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

    def self.rescue_from(e)
      BugBunny.configuration.logger.error("Controller Error: #{e.message}")
      { status: 500, error: e.message }
    end
  end
end
