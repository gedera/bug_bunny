# frozen_string_literal: true

# lib/bug_bunny/session.rb

module BugBunny
  # Clase interna que encapsula una unidad de trabajo sobre una conexión RabbitMQ.
  #
  # Su responsabilidad principal es gestionar el ciclo de vida de un `Bunny::Channel`.
  # En RabbitMQ, las conexiones TCP son costosas, pero los canales son ligeros.
  # Esta clase toma una conexión abierta del Pool, abre un canal exclusivo para esta sesión,
  # configura el QoS y facilita la creación de Exchanges y Colas.
  #
  # @api private
  class Session
    # Opciones por defecto para Exchanges: No durables, No auto-borrables.
    DEFAULT_EXCHANGE_OPTIONS = { durable: false, auto_delete: false }.freeze

    # Opciones por defecto para Colas: No exclusivas, No durables, Auto-borrables.
    # @note Por defecto las colas son volátiles (`auto_delete: true`). Para workers persistentes,
    #   se debe pasar explícitamente `durable: true, auto_delete: false`.
    DEFAULT_QUEUE_OPTIONS = { exclusive: false, durable: false, auto_delete: true }.freeze

    # @return [Bunny::Session] La conexión TCP subyacente.
    attr_reader :connection

    # @return [Bunny::Channel] El canal AMQP abierto para esta sesión.
    attr_reader :channel

    # Inicializa una nueva sesión.
    #
    # 1. Verifica que la conexión esté viva.
    # 2. Abre un nuevo canal.
    # 3. Habilita "Publisher Confirms" para garantizar que los mensajes lleguen al broker.
    # 4. Configura el "Prefetch" (QoS) global para este canal.
    #
    # @param connection [Bunny::Session] Una conexión abierta.
    # @raise [BugBunny::Error] Si la conexión es nil o está cerrada.
    def initialize(connection)
      raise BugBunny::Error, 'Connection is closed or nil' unless connection&.open?

      @connection = connection
      # Creamos canal nuevo para esta sesión (Thread-safe dentro del contexto del Pool)
      @channel = connection.create_channel
      @channel.confirm_select
      @channel.prefetch(BugBunny.configuration.channel_prefetch)
    end

    # Factory method para declarar o recuperar un Exchange.
    #
    # @param name [String, nil] El nombre del exchange. Si es nil/vacío, retorna el Default Exchange.
    # @param type [String, Symbol] El tipo de exchange (:direct, :topic, :fanout, :headers).
    # @param opts [Hash] Opciones de configuración (durable, auto_delete, arguments).
    # @return [Bunny::Exchange] La instancia del exchange.
    def exchange(name: nil, type: 'direct', opts: {})
      return channel.default_exchange if name.nil? || name.empty?

      merged_opts = DEFAULT_EXCHANGE_OPTIONS.merge(opts)
      case type.to_sym
      when :topic   then channel.topic(name, merged_opts)
      when :direct  then channel.direct(name, merged_opts)
      when :fanout  then channel.fanout(name, merged_opts)
      when :headers then channel.headers(name, merged_opts)
      else channel.direct(name, merged_opts)
      end
    end

    # Factory method para declarar o recuperar una Cola.
    #
    # @param name [String] El nombre de la cola.
    # @param opts [Hash] Opciones de configuración (durable, auto_delete, exclusive, arguments).
    # @return [Bunny::Queue] La instancia de la cola.
    def queue(name, opts = {})
      channel.queue(name.to_s, DEFAULT_QUEUE_OPTIONS.merge(opts))
    end

    # Cierra el canal asociado a esta sesión.
    # No cierra la conexión TCP (ya que esta pertenece al Pool), solo libera el canal virtual.
    #
    # @return [void]
    def close
      @channel.close if @channel&.open?
    end
  end
end
