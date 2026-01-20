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
  class << self
    attr_accessor :configuration
  end

  # Factory Method (Fachada Principal)
  # Uso: client = BugBunny.new(pool: MI_POOL)
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

  # Helper para desconexión global (usado por Railtie)
  def self.disconnect
    BugBunny::Rabbit.disconnect
  end
  
  # === ESTE ES EL MÉTODO QUE TE FALTABA ===
  def self.create_connection
    bunny = Bunny.new(
      host: configuration.host,
      username: configuration.username,
      password: configuration.password,
      vhost: configuration.vhost,
      logger: configuration.logger,
      automatically_recover: configuration.automatically_recover,
      network_recovery_interval: configuration.network_recovery_interval,
      connection_timeout: configuration.connection_timeout,
      read_timeout: configuration.read_timeout,
      write_timeout: configuration.write_timeout,
      heartbeat: configuration.heartbeat,
      continuation_timeout: configuration.continuation_timeout
    )
    bunny.start
    bunny
  rescue Timeout::Error, Bunny::ConnectionError => e
    raise BugBunny::CommunicationError, e.message
  end
end
