require 'active_model'
require 'rack'

module BugBunny
  class Controller
    include ActiveModel::Model
    include ActiveModel::Attributes

    attribute :headers
    attribute :params
    attribute :raw_string
    attr_reader :rendered_response

    def self.before_actions
      @before_actions ||= Hash.new { |hash, key| hash[key] = [] }
    end

    def self.before_action(method_name, **options)
      actions = options.delete(:only) || []
      target = actions.empty? ? :_all_actions : actions
      Array(target).each do |action|
        key = action == :_all_actions ? :_all_actions : action.to_sym
        before_actions[key] << method_name
      end
    end

    def self.call(headers:, body: {})
      controller = new(headers: headers)
      controller.prepare_params(body)

      return controller.rendered_response unless controller.run_callbacks

      action_method = controller.headers[:action].to_sym
      if controller.respond_to?(action_method)
        controller.send(action_method)
      else
        raise NameError, "Action '#{action_method}' not found"
      end

      controller.rendered_response || { status: 204, body: nil }
    rescue StandardError => e
      rescue_from(e)
    end

    def render(status:, json: nil)
      code = Rack::Utils::SYMBOL_TO_STATUS_CODE[status] || 200
      @rendered_response = { status: code, body: json }
    end

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
      BugBunny.configuration.logger.error("Controller: #{e.message}")
      { status: 500, error: e.message }
    end
  end
end
