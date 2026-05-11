# frozen_string_literal: true

# Stubs livianos de Bunny para specs unitarios que no necesitan RabbitMQ real.

module BunnyMocks
  # Stub mínimo de `Bunny::Exchange`: cachea el bloque pasado a `on_return`
  # (Bunny lo invoca al recibir un `basic.return` del broker) y permite que
  # los specs disparen retornos sintéticos vía `fire_return`.
  class FakeExchange
    attr_reader :name, :type, :opts

    def initialize(name, type, opts = {})
      @name = name
      @type = type
      @opts = opts
    end

    def on_return(&block)
      @on_return_handler = block
    end

    def publish(_payload, _opts = {}); end

    def fire_return(return_info, properties, body)
      @on_return_handler&.call(return_info, properties, body)
    end
  end

  FakeChannel = Struct.new(:open) do
    def open?       = open
    def close       = (self.open = false)
    def confirm_select; end
    def prefetch(_n); end

    def topic(name, opts = {})   = exchange_for(name, 'topic', opts)
    def direct(name, opts = {})  = exchange_for(name, 'direct', opts)
    def fanout(name, opts = {})  = exchange_for(name, 'fanout', opts)
    def headers(name, opts = {}) = exchange_for(name, 'headers', opts)
    def default_exchange         = exchange_for('', 'direct', {})

    private

    def exchange_for(name, type, opts)
      @exchanges ||= {}
      @exchanges[name] ||= FakeExchange.new(name, type, opts)
    end
  end

  FakeConnection = Struct.new(:open, :channel_to_return) do
    def open?           = open
    def start           = (self.open = true)
    def create_channel  = channel_to_return
  end
end
