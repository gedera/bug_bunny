# frozen_string_literal: true

require_relative '../test_helper'
require 'connection_pool'

# Controlador Dummy en memoria
module Rabbit
  module Controllers
    class IntegrationTest < BugBunny::Controller
      def index
        # CORRECCIÓN: Usar 'render' en lugar de retornar un hash implícito.
        # Si solo retornas el valor, el Controller lo ignora y devuelve 204 (No Content).
        render status: 200, json: { message: 'pong' }
      end
    end
  end
end

class RpcFlowTest < Minitest::Test
  def setup
    skip "RabbitMQ no disponible" unless TestHelper.rabbitmq_available?

    # 1. Configuración Real
    BugBunny.configure do |c|
      c.host = 'localhost'
      c.username = 'wisproMQ'
      c.password = 'wisproMQ'
      c.port = 5672
      c.logger = Logger.new(nil)
    end

    # 2. Pool para el Cliente
    @pool = ConnectionPool.new(size: 1, timeout: 5) do
      BugBunny.create_connection
    end

    # 3. Consumer en hilo separado
    @conn_consumer = BugBunny.create_connection
    @queue_name = 'test_integration_queue'
    @exchange_name = 'test_integration_exchange'

    @consumer_thread = Thread.new do
      BugBunny::Consumer.subscribe(
        connection: @conn_consumer,
        queue_name: @queue_name,
        exchange_name: @exchange_name,
        routing_key: 'test_key',
        block: true
      )
    end
    sleep 0.5 # Esperar arranque
  end

  def teardown
    return unless @conn_consumer
    @conn_consumer.close
    @consumer_thread.kill
  end

  def test_rpc_request_response
    client = BugBunny::Client.new(pool: @pool)

    # Usamos request() para RPC
    response = client.request(
      'integration_test',
      body: {},
      exchange: @exchange_name,
      routing_key: 'test_key'
    )

    # Ahora sí esperamos 200 OK
    assert_equal 200, response['status']

    body = response['body']
    msg = body.is_a?(Hash) ? (body['message'] || body[:message]) : body
    assert_equal 'pong', msg
  end
end
