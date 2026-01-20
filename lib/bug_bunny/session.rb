module BugBunny
  # Clase interna. Wrappea una conexión del Pool.
  class Session
    DEFAULT_EXCHANGE_OPTIONS = { durable: false, auto_delete: false }.freeze
    DEFAULT_QUEUE_OPTIONS = { exclusive: false, durable: false, auto_delete: true }.freeze

    attr_reader :connection, :channel

    def initialize(connection)
      raise BugBunny::Error, "Connection is closed or nil" unless connection&.open?

      @connection = connection
      # Creamos canal nuevo para esta sesión
      @channel = connection.create_channel
      @channel.confirm_select
      @channel.prefetch(BugBunny.configuration.channel_prefetch)
    end

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

    def queue(name, opts = {})
      channel.queue(name.to_s, DEFAULT_QUEUE_OPTIONS.merge(opts))
    end

    def close
      @channel.close if @channel&.open?
    end
  end
end
