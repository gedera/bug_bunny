# lib/bug_bunny/session.rb

module BugBunny
  # Clase interna que encapsula una unidad de trabajo sobre una conexión RabbitMQ.
  #
  # Gestiona el ciclo de vida de un `Bunny::Channel` implementando:
  # 1. Carga Perezosa (Lazy Loading): El canal solo se abre al usarse.
  # 2. Resiliencia: Intenta recuperar la conexión TCP si está cerrada.
  #
  # @api private
  class Session
    # Opciones por defecto (Mantenemos las que tenías en tu repo)
    DEFAULT_EXCHANGE_OPTIONS = { durable: false, auto_delete: false }.freeze
    DEFAULT_QUEUE_OPTIONS = { exclusive: false, durable: false, auto_delete: true }.freeze

    # @return [Bunny::Session] La conexión TCP subyacente.
    attr_reader :connection

    # Inicializa una nueva sesión sin abrir canales todavía.
    #
    # @param connection [Bunny::Session] Una conexión (puede estar abierta o cerrada temporalmente).
    def initialize(connection)
      @connection = connection
      @channel = nil
    end

    # Obtiene el canal actual o crea uno nuevo si es necesario.
    #
    # Este método es el punto central de la robustez. Verifica la salud
    # de la conexión y del canal antes de devolverlo.
    #
    # @return [Bunny::Channel] Un canal abierto y configurado.
    # @raise [BugBunny::CommunicationError] Si no se puede restablecer la conexión.
    def channel
      # Si el canal existe y está abierto, lo devolvemos rápido.
      return @channel if @channel&.open?

      # Si no, intentamos asegurar la conexión y crear el canal.
      ensure_connection!
      create_channel!

      @channel
    end

    # Factory method para declarar o recuperar un Exchange.
    # Usa el método robusto `channel` internamente.
    #
    # @param name [String, nil] Nombre del exchange.
    # @param type [String, Symbol] Tipo de exchange.
    # @param opts [Hash] Opciones adicionales.
    def exchange(name: nil, type: 'direct', opts: {})
      return channel.default_exchange if name.nil? || name.empty?

      merged_opts = DEFAULT_EXCHANGE_OPTIONS.merge(opts)
      # public_send permite llamar a :topic, :direct, etc. dinámicamente
      channel.public_send(type, name, merged_opts)
    end

    # Factory method para declarar o recuperar una Cola.
    # Usa el método robusto `channel` internamente.
    #
    # @param name [String] Nombre de la cola.
    # @param opts [Hash] Opciones adicionales.
    def queue(name, opts = {})
      channel.queue(name.to_s, DEFAULT_QUEUE_OPTIONS.merge(opts))
    end

    # Cierra el canal asociado a esta sesión de forma segura.
    def close
      @channel&.close if @channel&.open?
      @channel = nil
    end

    private

    # Crea y configura un nuevo canal.
    # Asume que la conexión ya ha sido verificada por `ensure_connection!`.
    def create_channel!
      @channel = @connection.create_channel

      # Configuraciones globales de BugBunny
      @channel.confirm_select

      if BugBunny.configuration.channel_prefetch
        @channel.prefetch(BugBunny.configuration.channel_prefetch)
      end
    rescue StandardError => e
      raise BugBunny::CommunicationError, "Failed to create channel: #{e.message}"
    end

    # Garantiza que la conexión TCP esté abierta.
    # Si está cerrada, intenta reconectarla (Reconexión Transparente).
    def ensure_connection!
      return if @connection.open?

      BugBunny.configuration.logger.warn("[BugBunny] Connection lost. Attempting to reconnect...")
      @connection.start
    rescue StandardError => e
      BugBunny.configuration.logger.error("[BugBunny] Critical connection failure: #{e.message}")
      raise BugBunny::CommunicationError, "Could not reconnect to RabbitMQ: #{e.message}"
    end
  end
end
