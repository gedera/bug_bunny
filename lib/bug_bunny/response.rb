module BugBunny
  class Response
    attr_accessor :status, :response, :exception

    def initialize(attrs={})
      @status    = attrs[:status]
      @response  = attrs[:response]
      @exception = attrs[:exception]
    end

    def success?
      @status
    end
  end
end
