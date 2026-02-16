# frozen_string_literal: true

require 'logger'

module BugBunny
  # Clase de configuración global para la gema.
  class Configuration
    attr_accessor :host, :port, :username, :password, :vhost, :logger, :bunny_logger,
                  :automatically_recover, :connection_timeout, :read_timeout, :write_timeout,
                  :heartbeat, :continuation_timeout, :network_recovery_interval,
                  :health_check_interval, :rpc_timeout

    def initialize
      set_defaults
      setup_loggers
    end

    def to_h
      {
        host: host, port: port, username: username, password: password, vhost: vhost,
        automatically_recover: automatically_recover
      }
    end

    private

    def set_defaults
      set_connection_defaults
      set_tuning_defaults
    end

    def set_connection_defaults
      @host = '127.0.0.1'
      @port = 5672
      @username = 'guest'
      @password = 'guest'
      @vhost = '/'
      @automatically_recover = true
      @network_recovery_interval = 5.0
    end

    def set_tuning_defaults
      @connection_timeout = 10
      @read_timeout = 10
      @write_timeout = 10
      @heartbeat = 15
      @continuation_timeout = 15_000
      @health_check_interval = 30
      @rpc_timeout = 10
    end

    def setup_loggers
      @logger = Logger.new($stdout)
      @logger.level = Logger::INFO

      @bunny_logger = Logger.new($stdout)
      @bunny_logger.level = Logger::WARN
    end
  end
end
