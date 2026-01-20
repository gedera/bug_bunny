require 'bunny'
require 'logger'
require 'connection_pool'

require_relative 'bug_bunny/version'
require_relative 'bug_bunny/config'
require_relative 'bug_bunny/exception'
require_relative 'bug_bunny/request'
require_relative 'bug_bunny/session'
require_relative 'bug_bunny/producer'
require_relative 'bug_bunny/client'
require_relative 'bug_bunny/resource'
require_relative 'bug_bunny/rabbit'
require_relative 'bug_bunny/consumer'
require_relative 'bug_bunny/controller'

module BugBunny
  # class << self
  #   attr_accessor :configuration
  # end

  def self.new(**args)
    BugBunny::Client.new(**args)
  end

  def self.configure
    self.configuration ||= Config.new
    yield(configuration)
  end

  def self.configuration
    @configuration ||= Config.new
  end

  def self.disconnect
    BugBunny::Rabbit.disconnect
  end

  def self.create_connection(**options)
    default = configuration

    bunny = Bunny.new(
      host:                      options[:host]                      || default.host,
      username:                  options[:username]                  || default.username,
      password:                  options[:password]                  || default.password,
      vhost:                     options[:vhost]                     || default.vhost,
      logger:                    options[:logger]                    || default.logger,
      automatically_recover:     options[:automatically_recover]     || default.automatically_recover,
      network_recovery_interval: options[:network_recovery_interval] || default.network_recovery_interval,
      connection_timeout:        options[:connection_timeout]        || default.connection_timeout,
      read_timeout:              options[:read_timeout]              || default.read_timeout,
      write_timeout:             options[:write_timeout]             || default.write_timeout,
      heartbeat:                 options[:heartbeat]                 || default.heartbeat,
      continuation_timeout:      options[:continuation_timeout]      || default.continuation_timeout
    )

    bunny.start
    bunny
  rescue Timeout::Error, Bunny::ConnectionError => e
    raise BugBunny::CommunicationError, e.message
  end
end
