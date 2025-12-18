module BugBunny
  class Controller
    include ActiveModel::Model
    include ActiveModel::Attributes

    attribute :headers
    attribute :params
    attribute :raw_string

    attr_reader :rendered_response

    def self.before_actions
      # Nota el uso de '@' en lugar de '@@'
      @before_actions ||= Hash.new { |hash, key| hash[key] = [] }
    end

    def self.before_action(method_name, **options)
      actions = options.delete(:only) || []

      if actions.empty?
        before_actions[:_all_actions] << method_name
      else
        Array(actions).each do |action|
          before_actions[action.to_sym] << method_name
        end
      end
    end

    def _run_before_actions
      current_action = headers[:action].to_sym

      callbacks = self.class.before_actions[:_all_actions] + self.class.before_actions[current_action]

      callbacks.each do |method_name|
        send(method_name) if respond_to?(method_name, true)
        return false if @rendered_response
      end

      true
    end

    def render(status:, json: nil)
      @rendered_response = self.class.render(status: status, json: json)
    end

    def safe_parse_body(body)
      self.params ||= {}

      return if body.blank?

      case headers[:content_type]
      when 'application/json', 'application/x-www-form-urlencoded'
        if body.instance_of?(Hash)
          params.merge!(body.deep_symbolize_keys)
        else # es string
          params.merge!(ActiveSupport::JSON.decode(body).deep_symbolize_keys)
        end
      when 'text/plain'
        self.raw_string = body
      end
    end

    def self.status_code_number(code)
      codes = Rack::Utils::SYMBOL_TO_STATUS_CODE
      codes[:unprocessable_entity] = 422
      code = codes[code.to_sym] if codes.key?(code.to_sym)
      code
    end

    def self.render(status:, json: nil)
      status_number = status_code_number(status)
      { status: status_number, body: json }
    end

    def self.rescue_from(exception)
      render status: :internal_server_error, json: exception.message
    end

    def self.call(headers:, body: {})
      controller = new(headers: headers)

      controller.safe_parse_body(body)
      controller.params[:id] = headers[:id] if headers.key?(:id)
      controller.params.with_indifferent_access

      return controller.rendered_response unless controller._run_before_actions

      controller.send(controller.headers[:action])
    rescue NoMethodError => e # action controller no exist
      raise e
    rescue StandardError => e
      rescue_from(e)
    end
  end
end
