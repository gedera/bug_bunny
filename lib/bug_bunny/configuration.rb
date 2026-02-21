# frozen_string_literal: true

require 'logger'

module BugBunny
  # Clase de configuración global para la gema BugBunny.
  # Almacena las credenciales de conexión, timeouts y parámetros de ajuste de RabbitMQ,
  # así como las opciones por defecto para la declaración de infraestructura AMQP.
  #
  # @example Configuración en un inicializador (e.g., config/initializers/bug_bunny.rb)
  #   BugBunny.configure do |config|
  #     config.host = '127.0.0.1'
  #     config.exchange_options = { durable: true, auto_delete: false }
  #     config.health_check_file = '/tmp/bug_bunny_health'
  #   end
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

    # @return [String, nil] Ruta del archivo que se actualizará (touch) en cada health check exitoso.
    #   Ideal para sondas (probes) de orquestadores como Docker Swarm o Kubernetes.
    #   Si es `nil`, la funcionalidad de touchfile se desactiva.
    #   @example '/tmp/bug_bunny_health'
    attr_accessor :health_check_file

    # @return [String] Namespace base donde se buscarán los controladores (default: 'Rabbit::Controllers').
    attr_accessor :controller_namespace

    # @return [Array<Symbol, Proc, String>] Etiquetas para el log estructurado.
    attr_accessor :log_tags

    # @!group Configuración de Infraestructura Global

    # @return [Hash] Opciones globales por defecto para la declaración de Exchanges.
    #   Estas opciones se fusionarán con los valores por defecto de la gema y las específicas del recurso.
    #   @example { durable: true, auto_delete: false }
    attr_accessor :exchange_options

    # @return [Hash] Opciones globales por defecto para la declaración de Colas.
    #   Estas opciones se fusionarán con los valores por defecto de la gema y las específicas del recurso.
    #   @example { durable: true, exclusive: false }
    attr_accessor :queue_options

    # @!endgroup

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

      # Desactivado por defecto. El usuario debe especificar una ruta explícita para habilitarlo.
      @health_check_file = nil

      # Configuración por defecto para mantener compatibilidad
      @controller_namespace = 'Rabbit::Controllers'

      @log_tags = [:uuid]

      # Inicialización de opciones de infraestructura como hashes vacíos para permitir fusiones posteriores.
      @exchange_options = {}
      @queue_options = {}
    end

    # Construye la URL de conexión AMQP basada en los atributos configurados.
    # @return [String] URL formateada amqp://user:pass@host:port/vhost
    def url
      "amqp://#{username}:#{password}@#{host}:#{port}/#{vhost}"
    end
  end
end
