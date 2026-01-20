module BugBunny
  class Config
    attr_accessor :host, :username, :password, :vhost, :logger
    attr_accessor :automatically_recover, :network_recovery_interval
    attr_accessor :connection_timeout, :read_timeout, :write_timeout
    attr_accessor :heartbeat, :continuation_timeout, :channel_prefetch
    attr_accessor :rpc_timeout, :health_check_interval

    def initialize
      @logger = Logger.new(STDOUT)
      @automatically_recover = true
      @network_recovery_interval = 5
      @connection_timeout = 10
      @read_timeout = 30
      @write_timeout = 30
      @heartbeat = 15
      @continuation_timeout = 15_000
      @channel_prefetch = 1
      @rpc_timeout = 10
      @health_check_interval = 60
    end

    def url
      "amqp://#{username}:#{password}@#{host}/#{vhost}"
    end
  end
end
