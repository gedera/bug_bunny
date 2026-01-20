module BugBunny
  class Error < ::StandardError; end
  class CommunicationError < Error; end
  class ClientError < Error; end
  class ServerError < Error; end

  class RequestTimeout < ClientError; end
  class InternalServerError < ServerError; end

  class UnprocessableEntity < ClientError
    attr_reader :error_messages, :raw_response

    def initialize(response_body)
      @raw_response = response_body
      @error_messages = parse_errors(response_body)
      super('Validation failed on remote service')
    end

    private

    def parse_errors(body)
      return body if body.is_a?(Hash)

      JSON.parse(body) rescue {}
    end
  end
end
