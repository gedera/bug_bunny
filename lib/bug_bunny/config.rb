# lib/bug_bunny/config.rb
require 'logger'

module BugBunny
  # Clase de configuración global para la gema BugBunny.
  # Almacena las credenciales de conexión, timeouts y parámetros de ajuste de RabbitMQ.
  #
  # @example Configuración típica
  #   BugBunny.configure do |config|
  #     config.host = 'rabbit.local'
  #     config.rpc_timeout = 5
  #   end
  class Config
    # @return [String] Host o IP del servidor RabbitMQ (ej: 'localhost').
    attr_accessor :host

    # @return [String] Usuario para la autenticación (default: 'guest').
    attr_accessor :username

    # @return [String] Contraseña para la autenticación (default: 'guest').
    attr_accessor :password

    # @return [String] Virtual Host de RabbitMQ a utilizar (default: '/').
    attr_accessor :vhost

    # @return [Logger] Instancia del logger para depuración (default: Logger a STDOUT).
    attr_accessor :logger

    # @return [Boolean] Si `true`, Bunny intentará reconectar automáticamente ante fallos de red (default: true).
    attr_accessor :automatically_recover

    # @return [Integer] Tiempo en segundos a esperar antes de intentar reconectar (default: 5).
    attr_accessor :network_recovery_interval

    # @return [Integer] Timeout en segundos para establecer la conexión TCP inicial (default: 10).
    attr_accessor :connection_timeout

    # @return [Integer] Timeout en segundos para leer datos del socket TCP (default: 30).
    attr_accessor :read_timeout

    # @return [Integer] Timeout en segundos para escribir datos en el socket TCP (default: 30).
    attr_accessor :write_timeout

    # @return [Integer] Intervalo en segundos para enviar latidos (heartbeats) y mantener la conexión viva (default: 15).
    attr_accessor :heartbeat

    # @return [Integer] Timeout en milisegundos para operaciones de continuación RPC internas de Bunny (default: 15_000).
    attr_accessor :continuation_timeout

    # @return [Integer] Cantidad de mensajes que el consumidor pre-cargará antes de procesarlos (QoS) (default: 1).
    attr_accessor :channel_prefetch

    # @return [Integer] Tiempo máximo en segundos que el cliente esperará una respuesta RPC antes de lanzar {BugBunny::RequestTimeout} (default: 10).
    attr_accessor :rpc_timeout

    # @return [Integer] Intervalo en segundos para verificar que la cola del consumidor sigue existiendo (default: 60).
    attr_accessor :health_check_interval

    # Inicializa la configuración con valores por defecto seguros.
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

    # Construye la URL de conexión AMQP basada en los atributos configurados.
    # Útil para logs o herramientas externas.
    #
    # @return [String] La cadena de conexión en formato `amqp://user:pass@host/vhost`.
    def url
      "amqp://#{username}:#{password}@#{host}/#{vhost}"
    end
  end
end
