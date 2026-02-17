# frozen_string_literal: true

require_relative '../test_helper'
require 'connection_pool'

class FireAndForgetTest < Minitest::Test
  def setup
    skip "RabbitMQ no disponible" unless TestHelper.rabbitmq_available?

    # 1. Configuración
    BugBunny.configure do |c|
      c.host = 'localhost'
      c.username = 'wisproMQ'
      c.password = 'wisproMQ'
      c.port = 5672
      c.logger = Logger.new(nil)
    end

    @pool = ConnectionPool.new(size: 1, timeout: 5) { BugBunny.create_connection }

    # 2. Infraestructura de Test
    @queue_name = 'test_fire_queue'
    @exchange_name = 'test_fire_exchange'
    @routing_key = 'logs.error'

    # Usamos una Queue de Ruby para pasar el mensaje del Consumer al Test
    @message_bucket = Queue.new

    # 3. Consumidor "Espía"
    @conn_consumer = BugBunny.create_connection
    @consumer_thread = Thread.new do
      ch = @conn_consumer.create_channel
      # IMPORTANTE: Aquí declaramos el exchange como TOPIC
      x = ch.topic(@exchange_name)
      q = ch.queue(@queue_name).bind(x, routing_key: @routing_key)

      q.subscribe(block: true) do |delivery_info, properties, body|
        @message_bucket << {
          body: body,
          routing_key: delivery_info.routing_key
        }
      end
    end
    sleep 0.5 # Wait boot
  end

  def teardown
    return unless @conn_consumer
    @conn_consumer.close
    @consumer_thread.kill
  end

  def test_publish_directly
    client = BugBunny::Client.new(pool: @pool)
    payload = { system: 'payment', error: 'timeout' }

    # 1. Disparamos (Fire)
    client.publish(
      'logs/error',
      body: payload,
      exchange: @exchange_name,
      exchange_type: 'topic',
      routing_key: @routing_key
    )

    # 2. Verificamos asíncronamente
    received = nil
    Timeout.timeout(2) do
      received = @message_bucket.pop
    end

    # 3. Aserciones
    assert_equal payload.to_json, received[:body]
    assert_equal @routing_key, received[:routing_key]
  end
end
