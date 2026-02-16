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
require_relative 'bug_bunny/middleware'

require_relative 'bug_bunny/middleware/stack'
require_relative 'bug_bunny/middleware/raise_error'
require_relative 'bug_bunny/middleware/json_response'

# Punto de entrada principal y Namespace de la gema BugBunny.
#
# BugBunny es un framework ligero sobre RabbitMQ diseñado para simplificar
# patrones de mensajería (RPC y Fire-and-Forget) en aplicaciones Ruby on Rails.
#
# @see BugBunny::Client Para enviar mensajes.
# @see BugBunny::Resource Para mapear modelos remotos.
# @see BugBunny::Consumer Para procesar mensajes entrantes.
module BugBunny
  # Factory method (Alias) para instanciar un nuevo Cliente.
  #
  # @param args [Hash] Argumentos pasados al constructor de {BugBunny::Client}.
  # @return [BugBunny::Client] Una nueva instancia del cliente.
  def self.new(**args)
    BugBunny::Client.new(**args)
  end

  # Configura la librería globalmente.
  #
  # @example Configuración típica en un initializer
  #   BugBunny.configure do |config|
  #     config.host = 'localhost'
  #     config.username = 'guest'
  #     config.rpc_timeout = 5
  #   end
  #
  # @yield [config] Bloque de configuración.
  # @yieldparam config [BugBunny::Config] Objeto de configuración global.
  # @return [BugBunny::Config] La configuración actualizada.
  def self.configure
    self.configuration ||= Config.new
    yield(configuration)
  end

  # Accesor al objeto de configuración global (Singleton).
  #
  # @return [BugBunny::Config] La instancia de configuración actual.
  def self.configuration
    @configuration ||= Config.new
  end

  # Cierra la conexión global mantenida por {BugBunny::Rabbit}.
  # Útil para liberar recursos en scripts o tareas Rake al finalizar.
  #
  # @see BugBunny::Rabbit.disconnect
  # @return [void]
  def self.disconnect
    BugBunny::Rabbit.disconnect
  end

  # Crea una nueva conexión a RabbitMQ (Bunny Session).
  #
  # Este método fusiona la configuración global por defecto con las opciones
  # pasadas explícitamente como argumentos, dando prioridad a estas últimas.
  #
  # Maneja automáticamente el inicio de la conexión (`start`) y captura errores
  # de red comunes envolviéndolos en excepciones de BugBunny.
  #
  # @param options [Hash] Opciones de conexión que sobrescriben la configuración global.
  # @option options [String] :host Host de RabbitMQ.
  # @option options [String] :vhost Virtual Host.
  # @option options [String] :username Usuario.
  # @option options [String] :password Contraseña.
  # @option options [Logger] :logger Logger personalizado.
  # @option options [Boolean] :automatically_recover (true/false).
  # @option options [Integer] :network_recovery_interval Intervalo de reconexión.
  # @option options [Integer] :connection_timeout Timeout de conexión TCP.
  # @return [Bunny::Session] Una sesión de Bunny iniciada y lista para usar.
  # @raise [BugBunny::CommunicationError] Si no se puede establecer la conexión TCP.
  def self.create_connection(**options)
    default = configuration

    bunny = Bunny.new(
      host:                      options[:host]                      || default.host,
      username:                  options[:username]                  || default.username,
      password:                  options[:password]                  || default.password,
      vhost:                     options[:vhost]                     || default.vhost,
      logger:                    options[:logger]                    || default.bunny_logger,
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
