module BugBunny
  # Clase de configuración global para la gema.
  # Se configura usualmente en `config/initializers/bug_bunny.rb`.
  class Config
    # @return [String] Hostname o IP del servidor RabbitMQ.
    attr_accessor :host

    # @return [String] Usuario para autenticación.
    attr_accessor :username

    # @return [String] Contraseña para autenticación.
    attr_accessor :password

    # @return [String] Virtual Host de RabbitMQ.
    attr_accessor :vhost

    # @return [Logger] Logger personalizado (por defecto Rails.logger).
    attr_accessor :logger

    # @return [Boolean] Si true, intenta reconectar automáticamente tras un fallo de red.
    attr_accessor :automatically_recover

    # @return [Integer] Segundos de espera entre intentos de reconexión.
    attr_accessor :network_recovery_interval

    # @return [Integer] Timeout en segundos para establecer conexión TCP.
    attr_accessor :connection_timeout

    # @return [Integer] Timeout de lectura de socket.
    attr_accessor :read_timeout

    # @return [Integer] Timeout de escritura de socket.
    attr_accessor :write_timeout

    # @return [Integer] Iintervalo de tiempo (en segundos) en el que el cliente y el servidor deben enviarse un pequeño paquete ("latido"). Si no se recibe un heartbeat durante dos intervalos consecutivos, se asume que la conexión ha muerto (generalmente por un fallo de red o un proceso colgado), lo que dispara el mecanismo de recuperación.
    attr_accessor :heartbeat

    # @return [Integer] Timeout interno de protocolo AMQP (ms).
    attr_accessor :continuation_timeout

    # @return [Integer] Cantidad de mensajes a pre-cargar por consumidor (QoS).
    attr_accessor :channel_prefetch

    # @return [Integer] Tiempo máximo de espera (segundos) para respuestas RPC síncronas.
    attr_accessor :rpc_timeout

    # @return [Integer] Intervalo (segundos) para verificar salud de colas/exchanges.
    attr_accessor :health_check_interval

    def initialize
      @logger = $stdout
      @automatically_recover = false
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

    # Construye la URL de conexión AMQP.
    # @return [String] URL completa (ej: "amqp://user:pass@host/vhost").
    # @api private
    def url
      "amqp://#{username}:#{password}@#{host}/#{vhost}"
    end
  end
end
