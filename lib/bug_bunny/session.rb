# frozen_string_literal: true

module BugBunny
  # Wrapper alrededor de la sesión (Channel) de Bunny.
  #
  # Provee una capa de abstracción para gestionar la creación de exchanges y colas,
  # asegurando que siempre se use un canal abierto y gestionando opciones por defecto.
  class Session
    # Mapeo de tipos de exchange permitidos a sus métodos de creación en Bunny.
    EXCHANGE_TYPES = {
      'topic' => :topic,
      'fanout' => :fanout,
      'headers' => :headers,
      'direct' => :direct
    }.freeze

    private_constant :EXCHANGE_TYPES

    # @return [Bunny::Channel] El canal AMQP subyacente.
    attr_reader :channel

    # Inicializa una nueva sesión.
    #
    # @param connection [Bunny::Session] Una conexión TCP activa a RabbitMQ.
    def initialize(connection)
      @connection = connection
      @channel = connection.create_channel
    end

    # Declara o recupera un Exchange.
    #
    # @param name [String, nil] Nombre del exchange. Si es nil, retorna el default exchange.
    # @param type [String] Tipo de exchange ('direct', 'topic', 'fanout', 'headers').
    #   Si el tipo no es reconocido, se usará 'direct' por defecto.
    # @param opts [Hash] Opciones adicionales de declaración (durable, auto_delete, etc).
    # @return [Bunny::Exchange] La instancia del exchange declarado.
    def exchange(name: nil, type: 'direct', opts: {})
      return channel.default_exchange if name.nil? || name.empty?

      # Resolvemos el método a llamar usando el Hash (reduce AbcSize y elimina DuplicateBranch)
      method_name = EXCHANGE_TYPES.fetch(type.to_s, :direct)
      options = { durable: true }.merge(opts)

      channel.public_send(method_name, name, options)
    end

    # Declara o recupera una Cola.
    #
    # @param name [String] Nombre de la cola.
    # @param opts [Hash] Opciones de la cola (durable, exclusive, arguments, etc).
    # @return [Bunny::Queue] La instancia de la cola declarada.
    def queue(name, opts = {})
      options = { durable: true }.merge(opts)
      channel.queue(name, options)
    end

    # Cierra el canal actual.
    # Es importante cerrar los canales cuando ya no se necesitan para liberar recursos en RabbitMQ.
    #
    # @return [void]
    def close
      channel.close if channel.open?
    end
  end
end
