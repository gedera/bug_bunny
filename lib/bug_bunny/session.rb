# frozen_string_literal: true

module BugBunny
  # Clase interna que encapsula una unidad de trabajo sobre una conexión RabbitMQ.
  #
  # Implementa la lógica de "Configuración en Cascada" para Exchanges y Colas,
  # gestionando el ciclo de vida de un `Bunny::Channel` con resiliencia y carga perezosa.
  #
  # @api private
  class Session
    include BugBunny::Observability

    # @!group Opciones por Defecto (Nivel 1: Gema)

    # Opciones predeterminadas de la gema para Exchanges.
    DEFAULT_EXCHANGE_OPTIONS = { durable: false, auto_delete: false }.freeze

    # Opciones predeterminadas de la gema para Colas.
    DEFAULT_QUEUE_OPTIONS = { exclusive: false, durable: false, auto_delete: true }.freeze

    # @!endgroup

    # @return [Bunny::Session] La conexión TCP subyacente.
    attr_reader :connection

    # Inicializa una nueva sesión sin abrir canales todavía.
    #
    # @param connection [Bunny::Session] Una conexión (puede estar abierta o cerrada temporalmente).
    # @param publisher_confirms [Boolean] Si es `true`, el canal se abre en modo Publisher Confirms.
    #   Activar solo en sesiones de Producer. En sesiones de Consumer genera overhead innecesario
    #   ya que los replies RPC son fire-and-forget desde la perspectiva del servidor.
    def initialize(connection, publisher_confirms: true)
      @connection = connection
      @publisher_confirms = publisher_confirms
      @channel = nil
      @channel_mutex = Mutex.new
      @logger = BugBunny.configuration.logger
    end

    # Obtiene el canal actual o crea uno nuevo si es necesario.
    #
    # Este método es el punto central de la robustez. Verifica la salud
    # de la conexión y del canal antes de devolverlo.
    #
    # @return [Bunny::Channel] Un canal abierto y configurado.
    # @raise [BugBunny::CommunicationError] Si no se puede restablecer la conexión.
    def channel
      # Fast path: canal abierto, sin adquirir el mutex.
      return @channel if @channel&.open?

      # Slow path: adquirimos el mutex y verificamos de nuevo (double-checked locking).
      # Evita que múltiples threads creen canales simultáneamente cuando el canal cae.
      @channel_mutex.synchronize do
        return @channel if @channel&.open?

        ensure_connection!
        create_channel!
      end

      @channel
    end

    # Factory method para declarar o recuperar un Exchange aplicando la cascada de configuración.
    #
    # Jerarquía de fusión:
    # 1. Defaults de la gema (`DEFAULT_EXCHANGE_OPTIONS`)
    # 2. Configuración global (`BugBunny.configuration.exchange_options`)
    # 3. Opciones específicas pasadas como argumento (`opts`)
    #
    # @param name [String, nil] Nombre del exchange.
    # @param type [String, Symbol] Tipo de exchange ('direct', 'topic', 'fanout').
    # @param opts [Hash] Opciones específicas de infraestructura para este intercambio.
    # @return [Bunny::Exchange] El objeto exchange de Bunny configurado.
    def exchange(name: nil, type: 'direct', opts: {})
      return channel.default_exchange if name.nil? || name.empty?

      # Aplicación de la lógica de fusión en cascada
      merged_opts = DEFAULT_EXCHANGE_OPTIONS
                    .merge(BugBunny.configuration.exchange_options || {})
                    .merge(opts)

      # public_send permite llamar a :topic, :direct, etc. dinámicamente según el tipo
      channel.public_send(type.to_s, name.to_s, merged_opts)
    end

    # Factory method para declarar o recuperar una Cola aplicando la cascada de configuración.
    #
    # Jerarquía de fusión:
    # 1. Defaults de la gema (`DEFAULT_QUEUE_OPTIONS`)
    # 2. Configuración global (`BugBunny.configuration.queue_options`)
    # 3. Opciones específicas pasadas como argumento (`opts`)
    #
    # @param name [String] Nombre de la cola.
    # @param opts [Hash] Opciones específicas de infraestructura para esta cola.
    # @return [Bunny::Queue] El objeto cola de Bunny configurado.
    def queue(name, opts = {})
      # Aplicación de la lógica de fusión en cascada
      merged_opts = DEFAULT_QUEUE_OPTIONS
                    .merge(BugBunny.configuration.queue_options || {})
                    .merge(opts)

      channel.queue(name.to_s, merged_opts)
    end

    # Cierra el canal asociado a esta sesión de forma segura.
    # @return [void]
    def close
      @channel_mutex.synchronize do
        @channel&.close if @channel&.open?
        @channel = nil
      end
    end

    private

    # Crea y configura un nuevo canal con las preferencias globales.
    # Asume que la conexión ya ha sido verificada por `ensure_connection!`.
    #
    # @raise [BugBunny::CommunicationError] Si falla la creación del canal.
    def create_channel!
      @channel = @connection.create_channel

      @channel.confirm_select if @publisher_confirms

      @channel.prefetch(BugBunny.configuration.channel_prefetch) if BugBunny.configuration.channel_prefetch
    rescue StandardError => e
      raise BugBunny::CommunicationError, "Failed to create channel: #{e.message}"
    end

    # Garantiza que la conexión TCP esté abierta.
    # Si está cerrada, intenta reconectarla (Reconexión Transparente).
    #
    # @raise [BugBunny::CommunicationError] Si falla la reconexión.
    def ensure_connection!
      return if @connection.open?

      safe_log(:warn, 'session.reconnect_attempt')
      @connection.start
    rescue StandardError => e
      safe_log(:error, 'session.reconnect_failed', **exception_metadata(e))
      raise BugBunny::CommunicationError, "Could not reconnect to RabbitMQ: #{e.message}"
    end
  end
end
