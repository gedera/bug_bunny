# frozen_string_literal: true

# Stubs livianos de Bunny para specs unitarios que no necesitan RabbitMQ real.

module BunnyMocks
  FakeChannel = Struct.new(:open) do
    def open?       = open
    def close       = (self.open = false)
    def confirm_select; end
    def prefetch(_n); end
  end

  FakeConnection = Struct.new(:open, :channel_to_return) do
    def open?           = open
    def start           = (self.open = true)
    def create_channel  = channel_to_return
  end
end
