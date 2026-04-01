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
    # Reglas de validación por atributo.
    # Solo cubre los atributos de conexión y timeout — los demás (logger, procs, hashes)
    # son tipos arbitrarios que no tienen sentido validar de forma genérica.
    #
    # Claves soportadas:
    # - `:type`     — clase que debe responder `is_a?`
    # - `:required` — si `true`, nil o string vacío lanzan ConfigurationError
    # - `:range`    — rango válido de valores (solo para Integer)
    VALIDATIONS = {
      host: { type: String, required: true },
      port: { type: Integer, required: true, range: 1..65_535 },
      username: { type: String, required: true },
      password: { type: String, required: true },
      vhost: { type: String, required: true },
      heartbeat: { type: Integer, range: 0..3_600 },
      connection_timeout: { type: Integer, range: 1..300 },
      read_timeout: { type: Integer, range: 1..300 },
      write_timeout: { type: Integer, range: 1..300 },
      rpc_timeout: { type: Integer, range: 1..3_600 },
      channel_prefetch: { type: Integer, range: 1..10_000 }
    }.freeze

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

    # @return [Integer] Tiempo en segundos a esperar antes de intentar reconectar (base del backoff).
    attr_accessor :network_recovery_interval

    # @return [Integer, nil] Número máximo de intentos de reconexión del Consumer antes de rendirse.
    #   Si es `nil` (default), reintenta indefinidamente.
    attr_accessor :max_reconnect_attempts

    # @return [Integer] Techo en segundos para el backoff exponencial de reconexión (default: 60).
    attr_accessor :max_reconnect_interval

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

    # @return [BugBunny::ConsumerMiddleware::Stack] Stack de middlewares ejecutados antes de procesar cada mensaje.
    #   Los middlewares se registran con {BugBunny::ConsumerMiddleware::Stack#use}.
    attr_reader :consumer_middlewares

    # @return [Proc, nil] Callback invocado justo antes del `basic_publish` del reply RPC.
    #   Debe retornar un Hash de headers AMQP a inyectar en la respuesta.
    #   Ideal para propagar trace context (ej: X-Amzn-Trace-Id) generado por el consumer.
    #   @example
    #     config.rpc_reply_headers = -> { { 'X-Amzn-Trace-Id' => ExisRay::Tracer.generate_trace_header } }
    attr_accessor :rpc_reply_headers

    # @return [Proc, nil] Callback invocado en el thread llamante tras recibir el reply RPC,
    #   con los headers AMQP de la respuesta. Permite hidratar trace context en el publisher.
    #   @example
    #     config.on_rpc_reply = ->(headers) { ExisRay::Tracer.hydrate(headers['X-Amzn-Trace-Id']) }
    attr_accessor :on_rpc_reply

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
      @max_reconnect_attempts = nil
      @max_reconnect_interval = 60
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
      @controller_namespace = 'BugBunny::Controllers'

      @log_tags = [:uuid]

      # Inicialización de opciones de infraestructura como hashes vacíos para permitir fusiones posteriores.
      @exchange_options = {}
      @queue_options = {}

      @consumer_middlewares = ConsumerMiddleware::Stack.new
      @rpc_reply_headers = nil
      @on_rpc_reply = nil
    end

    # Construye la URL de conexión AMQP basada en los atributos configurados.
    # @return [String] URL formateada amqp://user:pass@host:port/vhost
    def url
      "amqp://#{username}:#{password}@#{host}:#{port}/#{vhost}"
    end

    # Valida todos los atributos definidos en {VALIDATIONS}.
    # Se invoca automáticamente al final de {BugBunny.configure}.
    #
    # @raise [BugBunny::ConfigurationError] Si algún atributo es inválido.
    # @return [void]
    def validate!
      VALIDATIONS.each do |attr, rules|
        value = send(attr)
        validate_required!(attr, value, rules)
        next if value.nil?

        validate_type!(attr, value, rules)
        validate_range!(attr, value, rules)
      end
    end

    private

    def validate_required!(attr, value, rules)
      return unless rules[:required]
      return unless value.nil? || (value.is_a?(String) && value.empty?)

      raise BugBunny::ConfigurationError, "#{attr} is required"
    end

    def validate_type!(attr, value, rules)
      return unless rules[:type]
      return if value.is_a?(rules[:type])

      raise BugBunny::ConfigurationError,
            "#{attr} must be a #{rules[:type]}, got #{value.class}"
    end

    def validate_range!(attr, value, rules)
      return unless rules[:range]
      return if rules[:range].cover?(value)

      raise BugBunny::ConfigurationError,
            "#{attr} must be in #{rules[:range]}, got #{value.inspect}"
    end
  end
end
