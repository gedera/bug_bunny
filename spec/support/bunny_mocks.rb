# frozen_string_literal: true

# Stubs livianos de Bunny para specs unitarios que no necesitan RabbitMQ real.

module BunnyMocks
  FakeChannel = Struct.new(:open) do
    def open?       = open
    def close       = (self.open = false)
    def confirm_select; end
    def prefetch(_n); end

    # Captura el bloque pasado a `on_return` para que los specs puedan dispararlo.
    def on_return(&block)
      @on_return_handler = block
    end

    # Helper de specs: simula que el broker retornó un mensaje al canal.
    def fire_return(return_info, properties, body)
      @on_return_handler&.call(return_info, properties, body)
    end
  end

  FakeConnection = Struct.new(:open, :channel_to_return) do
    def open?           = open
    def start           = (self.open = true)
    def create_channel  = channel_to_return
  end
end
