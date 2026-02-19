# frozen_string_literal: true

require_relative '../test_helper'
require 'timeout'

module ManualTest
  class EchoController < BugBunny::Controller
    def index
      render status: 200, json: { 
        received: params[:message],
        type: headers[:type],
        via: 'ManualTest::EchoController'
      }
    end
  end
end

class ManualClientTest < Minitest::Test
  include IntegrationHelper

  def setup
    skip "RabbitMQ no disponible" unless IntegrationHelper.rabbitmq_available?
    
    # 1. NOMBRES ÚNICOS: Evitamos colisiones entre tests de diferentes tipos (Direct/Fanout)
    @queue = "test_manual_q_#{SecureRandom.hex(4)}"
    @exchange = "test_manual_x_#{SecureRandom.hex(4)}"
    
    @client = BugBunny::Client.new(pool: TEST_POOL)
    BugBunny.configure { |c| c.controller_namespace = 'ManualTest' }
  end

  def teardown
    BugBunny.configure { |c| c.controller_namespace = 'Rabbit::Controllers' }
  end

  # ==========================================
  # GRUPO 1: PUBLICACIÓN ASÍNCRONA (PUBLISH)
  # ==========================================

  def test_publish_topic
    puts "\n  -> [Manual] Publish (Topic)..."
    with_spy_worker(queue: @queue, exchange: @exchange, exchange_type: 'topic', routing_key: 'logs.#') do |messages|
      
      @client.publish('logs.error', exchange: @exchange, exchange_type: 'topic', body: { a: 1 })
      
      msg = wait_for_message(messages)
      assert_equal 'logs.error', msg[:routing_key]
    end
  end

  def test_publish_direct
    puts "  -> [Manual] Publish (Direct)..."
    with_spy_worker(queue: @queue, exchange: @exchange, exchange_type: 'direct', routing_key: 'alert') do |messages|
      
      @client.publish('alert', exchange: @exchange, exchange_type: 'direct', body: { a: 1 })
      
      msg = wait_for_message(messages)
      assert_equal 'alert', msg[:routing_key]
    end
  end

  def test_publish_fanout
    puts "  -> [Manual] Publish (Fanout)..."
    with_spy_worker(queue: @queue, exchange: @exchange, exchange_type: 'fanout', routing_key: '') do |messages|
      
      @client.publish('ignored.key', exchange: @exchange, exchange_type: 'fanout', body: { a: 1 })
      
      msg = wait_for_message(messages)
      assert_equal 'ignored.key', msg[:routing_key]
    end
  end

  # ==========================================
  # GRUPO 2: RPC SÍNCRONO (REQUEST)
  # ==========================================

  def test_request_topic
    puts "  -> [Manual] RPC (Topic)..."
    with_running_worker(queue: @queue, exchange: @exchange, exchange_type: 'topic', routing_key: 'echo') do
      
      response = @client.request('echo', 
        method: :get, exchange: @exchange, exchange_type: 'topic', 
        body: { message: 'topic_rpc' }
      )
      assert_equal 'topic_rpc', response['body']['received']
    end
  end

  def test_request_direct
    puts "  -> [Manual] RPC (Direct)..."
    direct_key = 'rpc.direct'
    
    with_running_worker(queue: @queue, exchange: @exchange, exchange_type: 'direct', routing_key: direct_key) do
      
      response = @client.request('echo',
        method: :get,
        routing_key: direct_key, 
        exchange: @exchange, 
        exchange_type: 'direct', 
        body: { message: 'direct_rpc' }
      )

      assert_equal 200, response['status']
      assert_equal 'direct_rpc', response['body']['received']
    end
  end

  def test_request_fanout
    puts "  -> [Manual] RPC (Fanout)..."
    with_running_worker(queue: @queue, exchange: @exchange, exchange_type: 'fanout', routing_key: '') do
      
      response = @client.request('echo', 
        method: :get,
        routing_key: 'random.ignored', 
        exchange: @exchange, 
        exchange_type: 'fanout', 
        body: { message: 'fanout_rpc' }
      )

      assert_equal 200, response['status']
      assert_equal 'fanout_rpc', response['body']['received']
    end
  end

  private

  def wait_for_message(queue, timeout_sec = 2)
    Timeout.timeout(timeout_sec) { queue.pop }
  rescue Timeout::Error
    flunk "Timeout: No llegó el mensaje al Worker en #{timeout_sec}s"
  end
end
