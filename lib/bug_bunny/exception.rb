module BugBunny
  class Exception

    class ServiceError < StandardError
      def to_s
        :service_error
      end
    end

    class NeedSignature < StandardError
      def to_s
        :need_signature
      end
    end

    class InvalidSignature < StandardError
      def to_s
        :invalid_signature
      end
    end

    class GatewayError < StandardError
      def to_s
        :gateway_error
      end
    end

    class UltraCriticError < StandardError
    end

    class ComunicationRabbitError < StandardError
      attr_accessor :backtrace

      def initialize(msg, backtrace)
        @backtrace = backtrace
        super(msg)
      end
    end

    class RetryWithoutError < StandardError
      def to_s
        "retry_sidekiq_without_error"
      end

      def backtrace
        []
      end
    end

    ServiceClasses = [
      Exception::NeedSignature,
      Exception::InvalidSignature,
      Exception::ServiceError,
      Exception::GatewayError,
      Exception::RetryWithoutError
    ]

    # Exceptions from ActiveRecord::StatementInvalid
    PG_EXCEPTIONS_TO_EXIT = %w[PG::ConnectionBad PG::UnableToSend].freeze
  end
end
