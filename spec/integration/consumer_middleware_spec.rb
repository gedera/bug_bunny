# frozen_string_literal: true

require 'spec_helper'
require 'support/integration_helper'

module MiddlewareSpec
  class PingController < BugBunny::Controller
    def index
      render status: 200, json: { pong: true }
    end
  end
end

# Middleware de prueba que registra las llamadas en un array compartido
class TrackingMiddleware < BugBunny::ConsumerMiddleware::Base
  def self.calls
    @calls ||= []
  end

  def self.reset!
    @calls = []
  end

  def call(delivery_info, properties, body)
    self.class.calls << {
      routing_key: delivery_info.routing_key,
      headers: properties.headers
    }
    @app.call(delivery_info, properties, body)
  end
end

RSpec.describe 'Consumer Middleware Stack', :integration do
  let(:queue)    { unique('middleware_q') }
  let(:exchange) { unique('middleware_x') }
  let(:client)   { BugBunny::Client.new(pool: TEST_POOL) }

  before do
    BugBunny.configure { |c| c.controller_namespace = 'MiddlewareSpec' }
    TrackingMiddleware.reset!
    BugBunny.consumer_middlewares.use TrackingMiddleware
  end

  after do
    BugBunny.configure { |c| c.controller_namespace = 'BugBunny::Controllers' }
    # Limpiamos el middleware para no afectar otros specs
    BugBunny.configuration.instance_variable_set(:@consumer_middlewares,
                                                 BugBunny::ConsumerMiddleware::Stack.new)
  end

  it 'ejecuta el middleware antes de process_message' do
    with_running_worker(queue: queue, exchange: exchange, routing_key: 'ping') do
      client.request('ping', method: :get, exchange: exchange, exchange_type: 'topic', routing_key: 'ping')

      expect(TrackingMiddleware.calls).not_to be_empty
      expect(TrackingMiddleware.calls.first[:routing_key]).to eq('ping')
    end
  end

  it 'ejecuta el middleware para cada mensaje recibido' do
    with_running_worker(queue: queue, exchange: exchange, routing_key: 'ping') do
      3.times { client.request('ping', method: :get, exchange: exchange, exchange_type: 'topic', routing_key: 'ping') }

      expect(TrackingMiddleware.calls.length).to eq(3)
    end
  end

  describe 'rpc_reply_headers' do
    it 'inyecta headers en el reply del consumer' do
      received_headers = nil

      BugBunny.configuration.rpc_reply_headers = -> { { 'X-Test-Header' => 'from-consumer' } }
      BugBunny.configuration.on_rpc_reply = ->(headers) { received_headers = headers }

      with_running_worker(queue: queue, exchange: exchange, routing_key: 'ping') do
        client.request('ping', method: :get, exchange: exchange, exchange_type: 'topic', routing_key: 'ping')
      end

      expect(received_headers).not_to be_nil
      expect(received_headers['X-Test-Header']).to eq('from-consumer')
    ensure
      BugBunny.configuration.rpc_reply_headers = nil
      BugBunny.configuration.on_rpc_reply      = nil
    end

    it 'incluye los campos OTel semantic conventions en el reply' do
      received_headers = nil

      BugBunny.configuration.rpc_reply_headers = -> { { 'X-Test-Header' => 'from-consumer' } }
      BugBunny.configuration.on_rpc_reply = ->(headers) { received_headers = headers }

      with_running_worker(queue: queue, exchange: exchange, routing_key: 'ping') do
        client.request('ping', method: :get, exchange: exchange, exchange_type: 'topic', routing_key: 'ping')
      end

      expect(received_headers).to include(
        'messaging_system' => 'rabbitmq',
        'messaging_operation' => 'publish',
        'X-Test-Header' => 'from-consumer'
      )
      expect(received_headers['messaging_message_id']).not_to be_nil
    ensure
      BugBunny.configuration.rpc_reply_headers = nil
      BugBunny.configuration.on_rpc_reply      = nil
    end
  end
end
