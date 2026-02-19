# frozen_string_literal: true

require 'bundler/setup'
require 'minitest/autorun'
# require 'minitest/reporters' 
require 'bug_bunny'
require 'connection_pool'
require 'securerandom'
require 'socket'

BugBunny.configure do |config|
  config.host = ENV.fetch('RABBITMQ_HOST', 'localhost')
  config.username = ENV.fetch('RABBITMQ_USER', 'guest')
  config.password = ENV.fetch('RABBITMQ_PASS', 'guest')
  config.vhost = '/'
  config.logger = Logger.new($stdout)
  config.logger.level = Logger::WARN 

  # ========================================================
  # LA MAGIA DE LA CASCADA (Nivel 2: Configuración Global)
  # ========================================================
  # Para los tests, queremos que los exchanges y queues sean efímeros
  config.exchange_options = { durable: false, auto_delete: true }
  config.queue_options    = { exclusive: false, durable: false, auto_delete: true }
end

TEST_POOL = ConnectionPool.new(size: 5, timeout: 5) { BugBunny.create_connection }
BugBunny::Resource.connection_pool = TEST_POOL

module IntegrationHelper
  def self.rabbitmq_available?
    socket = TCPSocket.new(BugBunny.configuration.host, 5672)
    socket.close
    true
  rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT, SocketError
    false
  end

  def with_running_worker(queue:, exchange:, exchange_type: 'topic', routing_key: '#')
    conn = BugBunny.create_connection
    
    worker_thread = Thread.new do
      ch = conn.create_channel
      
      x_opts = BugBunny.configuration.exchange_options || {}
      q_opts = BugBunny.configuration.queue_options || {}

      # FIX: Usamos la API de alto nivel (public_send) idéntica a BugBunny::Session
      ch.public_send(exchange_type, exchange, x_opts)
      ch.close

      BugBunny::Consumer.subscribe(
        connection: conn,
        queue_name: queue,
        exchange_name: exchange,
        exchange_type: exchange_type,
        routing_key: routing_key,
        queue_opts: q_opts,
        block: true
      )
    rescue => e
      puts "❌ WORKER CRASHED: #{e.message}"
      puts e.backtrace.join("\n")
    end

    sleep 0.5 
    yield
  ensure
    conn&.close
    worker_thread&.kill
    sleep 0.1
  end

  def with_spy_worker(queue:, exchange:, exchange_type: 'topic', routing_key: '#')
    captured_messages = Thread::Queue.new
    conn = BugBunny.create_connection
    
    worker_thread = Thread.new do
      ch = conn.create_channel
      
      x_opts = BugBunny.configuration.exchange_options || {}
      q_opts = BugBunny.configuration.queue_options || {}
      
      # FIX DEFINITIVO: Ahora 'x' es un hermoso objeto Bunny::Exchange
      # que la función .bind() entiende perfectamente.
      x = ch.public_send(exchange_type, exchange, x_opts)
      q = ch.queue(queue, q_opts)
      
      # Bindeamos el objeto al queue
      q.bind(x, routing_key: routing_key)

      q.subscribe(block: true) do |delivery, props, body|
        captured_messages << { 
          body: body, 
          routing_key: delivery.routing_key,
          headers: props.headers 
        }
      end
    rescue => e
      puts "SPY WORKER ERROR: #{e.message}"
    end

    sleep 0.5
    yield(captured_messages)
  ensure
    conn&.close
    worker_thread&.kill
  end
end
