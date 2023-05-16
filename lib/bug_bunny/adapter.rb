module BugBunny
  class Adapter
    PERSIST_MESSAGE = true

    SERVICE_HEALTH_CHECK = :health_check
    TIMEOUT             = 3
    BOMBA               = :bomba
    PUBLISH_TIMEOUT     = :publish_timeout
    CONSUMER_TIMEOUT    = :consumer_timeout
    COMUNICATION_ERROR  = :comunication_error
    CONSUMER_COUNT_ZERO = :consumer_count_zero

    PG_EXCEPTIONS_TO_EXIT = %w[PG::ConnectionBad PG::UnableToSend].freeze

    attr_accessor :consumer,
                  :rabbit,
                  :logger,
                  :time_to_wait,
                  :communication_response,
                  :service_message,
                  :consume_response

    def initialize
      @logger = Logger.new('./log/bug_bunny.log', 'monthly')
      @communication_response = ::BugBunny::Response.new status: false
      @time_to_wait = 2
      create_adapter_with_rabbit
    end

    def publish!(message, publish_queue, opts = {})
      Timeout::timeout(TIMEOUT) do
        if opts[:check_consumers_count] && publish_queue.check_consumers.zero?
          self.communication_response = ::BugBunny::Response.new(status: false, response: CONSUMER_COUNT_ZERO)
          return
        end

        publish_opts = { routing_key: publish_queue.name,
                         persistent: opts[:persistent],
                         correlation_id: message.correlation_id }

        publish_opts[:reply_to] = opts[:reply_to] if opts[:reply_to]

        # Esta es la idea en el caso que nos pongamos mas mañosos y queramos cambiar las exchange a la hora de publicar.
        # _exchange = if opts.has_key?(:exchange_type)
        #               channel.exchange(opts[:exchange_type].to_s, { type: opts[:exchange_type] })
        #             else
        #               exchange
        #             end
        # _exchange.publish(message.to_json, publish_opts)
        logger.debug("#{publish_queue.name}-Send Request: (#{message})")

        rabbit.exchange.publish(message.to_json, publish_opts)
        rabbit.channel.wait_for_confirms if rabbit.confirm_select

        self.communication_response = ::BugBunny::Response.new(status: true)
      end
    rescue Timeout::Error => e
      logger.error(e)
      close_connection!
      self.communication_response = ::BugBunny::Response.new(status: false, response: PUBLISH_TIMEOUT, exception: e)
    rescue StandardError => e
      logger.error(e)
      close_connection!
      self.communication_response = ::BugBunny::Response.new(status: false, response: BOMBA, exception: e)
    end

    def consume!(queue, thread: false, manual_ack: true, exclusive: false, block: true, opts: {})
      Signal.trap('INT') { exit }

      logger.debug("Suscribe consumer to: #{queue.name}")
      logger.debug("ENTRO AL CONSUMER #{rabbit.try(:identifier)}")

      self.consumer = queue.rabbit_queue.subscribe(manual_ack: manual_ack, exclusive: exclusive, block: block) do |delivery_info, metadata, json_payload|
        # Session depends on thread info, subscribe block cleans thread info
        # ::Session.init unless Session.tags_context

        begin
          payload = ActiveSupport::JSON.decode(json_payload).deep_symbolize_keys # Timezones pulenteado
        rescue StandardError
          payload = JSON.parse(json_payload).deep_symbolize_keys
        end

        # Session for Sentry logger
        # locale, version, service_name
        # payload.except(:body, :service_name).each do |k, v|
        #   Session.assign(k, v)
        # end
        # Session.from_service = payload[:service_name]
        # Session.correlation_id = metadata.correlation_id
        # Session.queue_name = queue.name

        unless defined?(ActiveRecord) && ActiveRecord::Base.connection_pool.with_connection(&:active?)
          logger.error('[PG] PG connection down')
          exit 7
        end

        begin
          message = ::BugBunny::Message.new(correlation_id: metadata.correlation_id, reply_to: metadata.reply_to, **payload)

          # Default sentry info
          # ::Session.request_id = message.correlation_id rescue nil
          # ::Session.tags_context.merge!(
          #   server_version: message.version,
          #   service_action: message.service_action,
          #   service_name:   message.service_name,
          #   isp_id:         (message.body&.fetch(:isp_id, nil) rescue nil)
          # )
          # ::Session.extra_context[:message] = message.body

          # definir este metodo en el adapter del servicio para setear el contexto del sentry a gusto
          logger.info("#{queue.name}-Received Request: (#{message.service_action})")
          logger.debug("#{queue.name}-Received Request: (#{message})")
          logger.debug("Message will be yield")
          logger.debug("Block given?  #{block_given?}")
          yield(message) if block_given?
          logger.debug('Message processed')

          begin
            Timeout.timeout(5) do
              rabbit.channel.ack delivery_info.delivery_tag if delivery_info[:consumer].manual_acknowledgement?
            end
          rescue Timeout::Error => e
            logger.debug("Rabbit Identifier: #{rabbit.try(:identifier)} can not check manual_ack #{e.to_s}")
          rescue ::StandardError => e
            logger.debug("Rabbit Identifier: #{rabbit.try(:identifier)} can not check manual_ack #{e.to_s}")
          end

          self.service_message = message
          self.communication_response = ::BugBunny::Response.new(status: true)
        rescue ::SystemExit => e # Ensure exit code
          raise e
        rescue => e
          logger.debug("Rabbit Identifier: #{rabbit.try(:identifier)}")
          logger.error(e)

          close_connection!

          # Session.clean!
          self.communication_response = ::BugBunny::Response.new(status: false, response: BOMBA, exception: e)
        end

        if thread # sync consumer flag :D
          begin
            Timeout::timeout(1) do
              delivery_info[:consumer].cancel
            end
          rescue Timeout::Error => e
            close_connection!
            thread.exit
          end
          close_connection!
          thread.exit
        end
      end

      if thread
        close_connection!
        thread.exit
      else
        while true
          begin
            logger.debug("SALIO DEL CONSUMER #{rabbit.try(:identifier)}")
            logger.debug(rabbit.status)
            exit # consumer.cancel
          rescue Bunny::NotAllowedError => e
            logger.debug("NOT ALLOWED #{e.to_s}")
            break
          rescue Timeout::Error => e
            if queue.rabbit_queue.channel.status == :closed || queue.rabbit_queue.channel.connection.status == :closed
              logger.debug("Channel or connection closed")
              break
            end

            sleep time_to_wait
            logger.debug("Rabbit Identifier: #{rabbit.try(:identifier)}")
            logger.error(e)
            retry
          rescue StandardError => e
            if queue.rabbit_queue.channel.status == :closed || queue.rabbit_queue.channel.connection.status == :closed
              logger.debug("Channel or connection closed")
              break
            end

            sleep time_to_wait
            logger.debug("Rabbit Identifier: #{rabbit.try(:identifier)}")
            logger.error(e)
            retry
          end
        end
      end
    rescue Timeout::Error => e
      logger.debug("Rabbit Identifier: #{rabbit.try(:identifier)}")
      logger.error(e)
      close_connection!
      ::BugBunny::Response.new(status: false, response: CONSUMER_TIMEOUT, exception: e)
    rescue StandardError => e
      logger.debug("Rabbit Identifier: #{rabbit.try(:identifier)}")
      logger.error(e)
      close_connection!
      ::BugBunny::Response.new(status: false, response: BOMBA, exception: e)
    end

    def publish_and_consume!(publish_message, sync_queue, opts={})
      reply_queue = build_queue('', initialize: true, exclusive: true, durable: false, auto_delete: true)

      retries = 0
      begin
        publish!(publish_message, sync_queue, opts.merge(reply_to: reply_queue.name))
      rescue
        if (retries += 1) <= 3
          sleep 0.5
          retry
        end

        close_connection!
        raise
      end

      return communication_response unless communication_response.success?

      t = Thread.new do
        retries = 0
        begin
          consume!(reply_queue, thread: Thread.current, exclusive: true) do |msg|
            yield(msg) if block_given?
          end
        rescue
          if (retries += 1) <= 3
            sleep 0.5
            retry
          end
          raise
        end
      end
      t.join
      communication_response
    end

    def build_queue(name, opts = {})
      init = opts.key?(:initialize) ? opts[:initialize] : true
      new_queue = ::BugBunny::Queue.new(opts.merge(name: name))

      if init
        logger.debug("Building rabbit new_queue: #{name} status: #{rabbit.status} queue_options: #{new_queue.options}")

        retries = 0
        begin
          built_queue = rabbit.channel.queue(new_queue.name.to_s, new_queue.options)
        rescue StandardError
          if (retries += 1) <= 3
            sleep 0.5
            retry
          end
          raise
        end

        new_queue.rabbit_queue = built_queue
        new_queue.name = new_queue.rabbit_queue.name
      end

      new_queue
    rescue Timeout::Error, StandardError => e
      logger.debug("Rabbit Identifier: #{rabbit.try(:identifier)}")
      logger.debug("Status adapter created: #{rabbit.status}")
      logger.error(e)

      close_connection!
      raise Exception::ComunicationRabbitError.new(COMUNICATION_ERROR, e.backtrace)
    end

    def self.make_response(comunication_result, consume_result = nil)
      if comunication_result.success?
        consume_result || comunication_result
      else
        comunication_result.response = comunication_result.response.to_s
        comunication_result
      end
    end

    def make_response
      if communication_response.success?
        consume_response || communication_response
      else
        communication_response.response = communication_response.response.to_s
        communication_response
      end
    end

    def status
      rabbit.try(:status)
    end

    def close_connection!
      rabbit.try(:close)
    end

    def check_pg_exception!(exception)
      # el consumidor no reconecta (rails tasks) asi que salimos a la goma
      if PG_EXCEPTIONS_TO_EXIT.any? { |msg| exception.try(:message)&.starts_with?(msg) }
        exit 7 # salimos con un int especial para identificarlo
      end
    end

    private

    # AMQ::Protocol::EmptyResponseError: Este error lo note cuando el rabbit
    # acepta la connection pero aun no ha terminado de inicializar el servicio,
    # por lo que salta esta exception.
    # Errno::ECONNRESET: Este error se presenta cuando justo esta arrancando
    # el rabbit y se quiere conectar al mismo. El rabbit resetea la connection,
    # haciendo saltar esta exception.
    def create_adapter_with_rabbit
      self.rabbit = ::BugBunny::Rabbit.new(confirm_select: true, logger: logger)
    rescue Bunny::NetworkFailure, Bunny::TCPConnectionFailed,
           Bunny::ConnectionForced, AMQ::Protocol::EmptyResponseError,
           Errno::ECONNRESET => e

      logger.debug(e)
      close_connection!
      raise Exception::ComunicationRabbitError.new(COMUNICATION_ERROR, e.backtrace)
    rescue OpenSSL::SSL::SSLError, OpenSSL::X509::CertificateError => e
      # el `e.to_s` devuelve alguno de los sgtes errores. Por ej:
      # SSL_connect returned=1 errno=0 state=unknown state: sslv3
      # alert bad certificate
      # SSL_CTX_use_PrivateKey: key values mismatch
      # OpenSSL::X509::CertificateError: not enough data // headers too short
      if respond_to?(:handle_ssl_issues)
        handle_ssl_issues # esto pide los certificados de nuevo
        @retries ||= 0
        @retries += 1
        sleep 1
        retry if @retries < 4
        @retries = 0 # reset the counter
      end

      # Si sigue fallando desp de 3 veces o no tiene definido el handle
      # bombita rodriguez
      logger.error(e)

      close_connection!
      raise Exception::ComunicationRabbitError.new(COMUNICATION_ERROR, e.backtrace)
    rescue Timeout::Error, StandardError => e
      logger.error(e)

      close_connection!
      raise Exception::ComunicationRabbitError.new(COMUNICATION_ERROR, e.backtrace)
    end

    def self.health_check(request: nil)
      message_to_publish = ::BugBunny::Message.new(service_action: self::SERVICE_HEALTH_CHECK, body: {})

      request ||= self::ROUTING_KEY_SYNC_REQUEST

      begin
        service_adapter = new
        sync_queue = service_adapter.build_queue(
          request,
          self::QUEUES_PROPS[self::ROUTING_KEY_SYNC_REQUEST]
        )
      rescue ::BugBunny::Exception::ComunicationRabbitError => e
        (service_adapter ||= nil).try(:close_connection!)
        return ::BugBunny::Response.new(status: false, response: e.message)
      end

      service_adapter.publish_and_consume!(message_to_publish, sync_queue, check_consumers_count: true)

      service_adapter.close_connection! # ensure the adapter is close

      if service_adapter.communication_response.success?
        msg = service_adapter.service_message

        result = case msg.status
                 when 'success'
                   { status: true }
                 when 'error', 'critical'
                   { status: false }
                 end

        service_adapter.consume_response = ::BugBunny::Response.new(result)
      end

      service_adapter.make_response
    end
  end
end
