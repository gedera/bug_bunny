# frozen_string_literal: true

require 'bunny'
require 'logger'
require_relative 'bug_bunny/version'
require_relative 'bug_bunny/exception'
require_relative 'bug_bunny/configuration'
require_relative 'bug_bunny/middleware/base'
require_relative 'bug_bunny/middleware/stack'
require_relative 'bug_bunny/middleware/raise_error'
require_relative 'bug_bunny/middleware/json_response'
require_relative 'bug_bunny/client'
require_relative 'bug_bunny/session'
require_relative 'bug_bunny/consumer'
require_relative 'bug_bunny/request'
require_relative 'bug_bunny/producer'
require_relative 'bug_bunny/resource'
require_relative 'bug_bunny/controller'
require_relative 'bug_bunny/railtie' if defined?(Rails)

# Módulo principal de la gema BugBunny.
# Actúa como espacio de nombres y punto de configuración global.
module BugBunny
  class << self
    # @return [BugBunny::Configuration] La configuración global actual.
    attr_accessor :configuration

    # @return [Bunny::Session, nil] La conexión global (Singleton) usada por procesos Rails.
    attr_accessor :global_connection
  end

  # Configura la librería BugBunny.
  # Si no se ha configurado previamente, inicializa una nueva configuración por defecto.
  #
  # @yieldparam config [BugBunny::Configuration] El objeto de configuración para modificar.
  # @return [void]
  def self.configure
    self.configuration ||= Configuration.new
    yield(configuration)
  end

  # Crea e inicia una nueva conexión a RabbitMQ utilizando la gema Bunny.
  # Mezcla las opciones pasadas explícitamente con la configuración global por defecto.
  #
  # @param options [Hash] Opciones de conexión que sobrescriben la configuración global.
  # @option options [String] :host ('127.0.0.1') Host del servidor RabbitMQ.
  # @option options [Integer] :port (5672) Puerto del servidor.
  # @option options [String] :username ('guest') Usuario de conexión.
  # @option options [String] :password ('guest') Contraseña.
  # @option options [String] :vhost ('/') Virtual Host.
  # @option options [Logger] :logger Logger para la conexión interna de Bunny.
  # @option options [Boolean] :automatically_recover (true) Si debe reconectar automáticamente.
  # @option options [Integer] :connection_timeout (10) Tiempo de espera para conectar.
  # @option options [Integer] :read_timeout (10) Tiempo de espera para lectura.
  # @option options [Integer] :write_timeout (10) Tiempo de espera para escritura.
  # @option options [Integer] :heartbeat (15) Intervalo de latidos en segundos.
  # @option options [Integer] :continuation_timeout (15000) Timeout para operaciones RPC internas.
  #
  # @return [Bunny::Session] Una sesión de Bunny ya iniciada (`start` ya invocado).
  # @raise [Bunny::TCPConnectionFailed] Si no se puede conectar al servidor.
  def self.create_connection(**options)
    conn_options = merge_connection_options(options)
    Bunny.new(conn_options).tap(&:start)
  end

  # Cierra la conexión global si existe.
  #
  # Este método es utilizado principalmente por el Railtie para asegurar que
  # los procesos hijos (forks) de servidores como Puma o Spring no hereden
  # la conexión TCP del proceso padre, forzando una reconexión limpia ("Lazy").
  #
  # @return [void]
  def self.disconnect
    return unless @global_connection

    @global_connection.close if @global_connection.open?
    @global_connection = nil
    configuration.logger.info('[BugBunny] 🔌 Global connection closed.')
  end

  # @api private
  # Fusiona las opciones del usuario con los valores por defecto de la configuración.
  def self.merge_connection_options(options)
    # .compact elimina los valores nil de options para no sobrescribir los defaults
    default_connection_options.merge(options.compact)
  end

  # @api private
  # Genera el hash de opciones por defecto basado en la configuración global.
  # Extraído para reducir la métrica AbcSize de merge_connection_options.
  def self.default_connection_options
    cfg = configuration || Configuration.new
    {
      host: cfg.host, port: cfg.port,
      username: cfg.username, password: cfg.password, vhost: cfg.vhost,
      logger: cfg.bunny_logger, automatically_recover: cfg.automatically_recover,
      connection_timeout: cfg.connection_timeout, read_timeout: cfg.read_timeout,
      write_timeout: cfg.write_timeout, heartbeat: cfg.heartbeat,
      continuation_timeout: cfg.continuation_timeout
    }
  end

  private_class_method :merge_connection_options, :default_connection_options
end
