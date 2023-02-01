module BugBunny
  class Rabbit
    require 'bunny'

    attr_accessor :exchange,
                  :rabbit_channel,
                  :confirm_select,
                  :no_ack,
                  :persistent,
                  :block,
                  :logger,
                  :identifier,
                  :connection

    def initialize(attrs = {})
      @block          = attrs[:block] || true
      @no_ack         = attrs[:no_ack] || true
      @persistent     = attrs[:persistent] || true
      @confirm_select = attrs[:confirm_select] || true
      @logger         = attrs[:logger] || Logger.new('./log/bug_rabbit.log', 'monthly')
      @identifier = SecureRandom.uuid

      create_connection
      set_channel
    end

    def set_channel
      logger.debug("Set Channel: #{connection.status}") if logger
      try(:close_channel)
      @rabbit_channel = connection.create_channel
      @exchange = channel.default_exchange
      channel.confirm_select if confirm_select
      @rabbit_channel
    end

    def channel
      open? ? @rabbit_channel : set_channel
    end

    def close
      @rabbit_channel.close if defined?(@rabbit_channel)
      connection.close if connection.present?
    rescue Bunny::ChannelAlreadyClosed
      nil
    end

    def close_channel
      @rabbit_channel.close if defined?(@rabbit_channel)
    end

    def status
      {
        connection: connection.status,
        channel: @rabbit_channel.status,
        identifier: identifier
      }
    end

    def open?
      (connection.status == :open) &&
        (@rabbit_channel.status == :open)
    end

    def connection_openned?
      [:open, :connecting, :connected].include?(connection.status)
    end

    # status = :open, :connected, :connecting,
    # :closing, :disconnected, :not_connected, :closed
    def create_connection
      options = {}

      # if WisproUtils::Config.defaults.use_tls
      #   path = (Rails.root.join('private', 'certs') rescue './private/certs')
      #   options.merge!(tls:                 true,
      #                  port:                ENV['RABBIT_SSL_PORT'] || 5671,
      #                  log_level:           ENV['LOG_LEVEL'] || :debug,
      #                  verify_peer:         true,
      #                  tls_cert:            "#{path}/cert.pem",
      #                  tls_key:             "#{path}/key.pem",
      #                  tls_ca_certificates: ["#{path}/ca.pem"])
      # end

      logger&.debug('Stablish new connection to rabbit')
      logger&.debug("amqp://#{ENV['RABBIT_USER']}:" \
                   "#{ENV['RABBIT_PASS']}@#{ENV['RABBIT_HOST']}" \
                   "/#{ENV['RABBIT_VIRTUAL_HOST']}")


      bunny_logger = ::Logger.new('./log/bunny.log', 7, 10485760)
      bunny_logger.level = ::Logger::DEBUG
      options.merge!(
        heartbeat_interval: 20,  # 20.seconds per connection
        logger: bunny_logger,
        # Override bunny client_propierties
        client_properties: { product: identifier, platform: ''}
      )

      rabbit_conn = Bunny.new("amqp://#{ENV['RABBIT_USER']}" \
                              ":#{ENV['RABBIT_PASS']}@"\
                              "#{ENV['RABBIT_HOST']}/"\
                              "#{ENV['RABBIT_VIRTUAL_HOST']}",
                              options)
      rabbit_conn.start
      logger&.debug("New status connection: #{rabbit_conn.status}")

      self.connection = rabbit_conn
    end
  end
end
