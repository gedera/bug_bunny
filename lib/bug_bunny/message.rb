module BugBunny
  class Message
    # API ERROR RESPONSE KEY
    FIELD_ERROR   = :field
    SERVER_ERROR  = :server

    # API ERROR RESPONSE CODES
    MISSING_FIELD = :missing
    UNKNOWN_FIELD = :unknown
    NOT_FOUND     = :not_found
    NO_ACTION     = :no_action
    TIMEOUT       = :timeout
    BOMBA         = :bomba

    SCOPE_TRANSLATION = %i[adapter]

    attr_accessor :correlation_id,
                  :body,
                  :signature,
                  :errors,
                  :status,
                  :service_name,
                  :service_action,
                  :version,
                  :reply_to,
                  :exception,
                  :locale

    def initialize(opts = {})
      @correlation_id = opts[:correlation_id] || SecureRandom.uuid
      @body           = deserialize_body(opts[:body] || opts[:response] || {})
      @errors         = opts[:errors]
      @status         = opts[:status] || :success
      @service_name   = opts[:service_name]
      @service_action = opts[:service_action] # Deberiamos raisear si esto no viene...
      @version        = opts[:version]
      @signature      = opts[:signature]
      @reply_to       = opts[:reply_to]
      @exception      = opts[:exception]
      @locale         = (opts[:locale] || I18n.locale || :es)
    end

    def server_not_found!
      server_error! [NOT_FOUND]
    end

    def server_timeout!
      server_error! [TIMEOUT]
    end

    def server_no_action!
      server_error! [NO_ACTION]
    end

    def server_error!(errors=nil)
      self.status = :error
      self.body = {}
      if errors
        self.errors ||= {}
        self.errors[SERVER_ERROR] ||= []
        self.errors[SERVER_ERROR] += [errors].flatten # just in case
      else
        self.exception = Exception::ServiceError.new
      end
      self
    end

    def signed?
      signature.present?
    end

    def sign!(key)
      self.signature = ::BugBunny::Security.sign_message(key, body.to_json)
    end

    def invalid_signature?(key)
      !valid_signature?(key)
    end

    def valid_signature?(key)
      return if signature.blank?

      ::BugBunny::Security.check_sign(key, signature, body.to_json)
    end

    def formatted
      resp = {
        correlation_id: correlation_id,
        version:        version,
        status:         status,
        service_name:   service_name,
        service_action: service_action,
        locale:         locale,
        signature:      signature,
        errors:         errors,
        body:           serialize_body
      }

      if exception
        # resp[:exception] = exception.backtrace.join("\n") rescue nil
        resp[:exception] = [
          exception.to_s,
          exception.try(:backtrace) || []
        ].flatten.join("\n") rescue exception.to_s

        unless ::BugBunny::Exception::ServiceClasses.include?(exception.class)
          self.exception = Exception::ServiceError.new
        end
        resp[:errors] ||= {}
        unless resp[:errors][SERVER_ERROR]&.any?
          resp[:errors][SERVER_ERROR] ||= []
          resp[:errors][SERVER_ERROR] << exception.to_s
        end
        resp[:status] = self.status = :critical
      end

      resp
    end

    def to_json
      formatted.to_json
    end

    def to_s
      to_json # Asegurarse de que siempre se llame al "formatted"
    end

    def to_h
      formatted
    rescue StandardError
      original_to_h
    end

    alias :original_to_h :to_h

    def success?
      status.to_sym == :success
    end

    def error?
      status.to_sym == :error
    end

    def critical?
      status.to_sym == :critical
    end

    def build_message(params = {})
      Message.new({ version: version, correlation_id: correlation_id, service_action: service_action }.merge(params))
    end

    def serialize_body
      Helpers.datetime_values_to_utc(body)
    end

    def deserialize_body(body)
      Helpers.utc_values_to_local(body)
    end

    def critical_response
      ::BugBunny::ParserMessage.humanize_error(errors, :adapter)
    rescue StandarError
      [I18n.t(:general_error, scope: :adapter)]
    end
  end
end
