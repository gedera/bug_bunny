# frozen_string_literal: true

require 'logger'

module BugBunny
  # Clase de configuración global para la gema.
  # Almacena las credenciales, timeouts y opciones de comportamiento de RabbitMQ.
  class Configuration
    # @return [String] Host del servidor RabbitMQ (default: '127.0.0.1').
    attr_accessor :host

    # @return [Integer] Puerto del servidor RabbitMQ (default: 5672).
    attr_accessor :port

    # @return [String] Usuario para la autenticación (default: 'guest').
    attr_accessor :username

    # @return [String] Contraseña para la autenticación (default: 'guest').
    attr_accessor :password

    # @return [String] Virtual Host de RabbitMQ (default: '/').
    attr_accessor :vhost

    # @return [Logger] Logger principal de la gema (default: STDOUT).
    attr_accessor :logger

    # @return [Logger] Logger interno de la librería Bunny (default: STDOUT, level WARN).
    attr_accessor :bunny_logger

    # @return [Boolean] Habilita la reconexión automática en caso de fallo de red (default: true).
    attr_accessor :automatically_recover

    # @return [Integer] Tiempo de espera en segundos para establecer conexión TCP (default: 10).
    attr_accessor :connection_timeout

    # @return [Integer] Tiempo de espera en segundos para leer del socket (default: 10).
    attr_accessor :read_timeout

    # @return [Integer] Tiempo de espera en segundos para escribir en el socket (default: 10).
    attr_accessor :write_timeout

    # @return [Integer] Intervalo en segundos para enviar latidos (heartbeats) y
    #   mantener la conexión viva (default: 15).
    attr_accessor :heartbeat

    # @return [Integer] Timeout en milisegundos para operaciones de continuación RPC
    #   internas de Bunny (default: 15_000).
    attr_accessor :continuation_timeout

    # @return [Float] Intervalo en segundos entre intentos de reconexión (default: 5.0).
    attr_accessor :network_recovery_interval

    # @return [Integer] Intervalo en segundos para verificar la salud de las colas en consumidores (default: 30).
    attr_accessor :health_check_interval

    # @return [Integer] Tiempo máximo en segundos que el cliente esperará una respuesta RPC
    #   antes de lanzar {BugBunny::RequestTimeout} (default: 10).
    attr_accessor :rpc_timeout

    def initialize
      set_defaults
      setup_loggers
    end

    # @return [Hash] Representación en Hash de las opciones de conexión básicas.
    def to_h
      {
        host: host, port: port, username: username, password: password, vhost: vhost,
        automatically_recover: automatically_recover
      }
    end

    private

    def set_defaults
      @host = '127.0.0.1'
      @port = 5672
      @username = 'guest'
      @password = 'guest'
      @vhost = '/'
      @automatically_recover = true
      @connection_timeout = 10
      @read_timeout = 10
      @write_timeout = 10
      @heartbeat = 15
      @continuation_timeout = 15_000
      @network_recovery_interval = 5.0
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
