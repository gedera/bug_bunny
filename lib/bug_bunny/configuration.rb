# frozen_string_literal: true

require 'logger'

module BugBunny
  # Clase de configuración global para la gema BugBunny.
  # Almacena las credenciales de conexión, timeouts y parámetros de ajuste de RabbitMQ.
  class Configuration
    # @return [String] Host o IP del servidor RabbitMQ (ej: 'localhost').
    attr_accessor :host

    # @return [Integer] Puerto del servidor RabbitMQ (default: 5672).
    attr_accessor :port

    # @return [String] Usuario para la autenticación (default: 'guest').
    attr_accessor :username

    # @return [String] Contraseña para la autenticación (default: 'guest').
    attr_accessor :password

    # @return [String] Virtual Host de RabbitMQ a utilizar (default: '/').
    attr_accessor :vhost

    # @return [Logger] Instancia del logger para depuración (default: Logger a STDOUT).
    attr_accessor :logger

    # @return [Logger] Logger específico para el driver Bunny.
    attr_accessor :bunny_logger

    # @return [Boolean] Si `true`, Bunny intentará reconectar automáticamente.
    attr_accessor :automatically_recover

    # @return [Integer] Tiempo en segundos a esperar antes de intentar reconectar.
    attr_accessor :network_recovery_interval

    # @return [Integer] Timeout en segundos para establecer la conexión TCP inicial.
    attr_accessor :connection_timeout

    # @return [Integer] Timeout en segundos para leer datos del socket TCP.
    attr_accessor :read_timeout

    # @return [Integer] Timeout en segundos para escribir datos en el socket TCP.
    attr_accessor :write_timeout

    # @return [Integer] Intervalo en segundos para enviar latidos (heartbeats).
    attr_accessor :heartbeat

    # @return [Integer] Timeout en milisegundos para operaciones de continuación RPC internas.
    attr_accessor :continuation_timeout

    # @return [Integer] Cantidad de mensajes que el consumidor pre-cargará (QoS).
    attr_accessor :channel_prefetch

    # @return [Integer] Tiempo máximo en segundos que el cliente esperará una respuesta RPC.
    attr_accessor :rpc_timeout

    # @return [Integer] Intervalo en segundos para verificar la salud de la cola.
    attr_accessor :health_check_interval

    # @return [String] Namespace base donde se buscarán los controladores (default: 'Rabbit::Controllers').
    attr_accessor :controller_namespace

    # Inicializa la configuración con valores por defecto seguros.
    def initialize
      @host = '127.0.0.1'
      @port = 5672
      @username = 'guest'
      @password = 'guest'
      @vhost = '/'

      @logger = Logger.new($stdout)
      @logger.level = Logger::INFO

      @bunny_logger = Logger.new($stdout)
      @bunny_logger.level = Logger::WARN
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

      # Configuración por defecto para mantener compatibilidad
      @controller_namespace = 'Rabbit::Controllers'
    end

    # Construye la URL de conexión AMQP basada en los atributos configurados.
    def url
      "amqp://#{username}:#{password}@#{host}:#{port}/#{vhost}"
    end
  end
end
