# frozen_string_literal: true

require 'bundler/setup'
require 'minitest/autorun'
# require 'minitest/reporters' # Descomentar si agregaste la gema 'minitest-reporters'
require 'bug_bunny'
require 'connection_pool'
require 'securerandom'
require 'socket'

# Configuración visual (Opcional)
# Minitest::Reporters.use! Minitest::Reporters::SpecReporter.new if defined?(Minitest::Reporters)

# Configuración Base para Tests de Integración
BugBunny.configure do |config|
  config.host = ENV.fetch('RABBITMQ_HOST', 'localhost')
  config.username = ENV.fetch('RABBITMQ_USER', 'guest')
  config.password = ENV.fetch('RABBITMQ_PASS', 'guest')
  config.vhost = '/'
  
  # Logger limpio pero útil. Cambiar a DEBUG si algo falla.
  config.logger = Logger.new($stdout)
  config.logger.level = Logger::WARN 
end

# Pool Global de Test
TEST_POOL = ConnectionPool.new(size: 5, timeout: 5) { BugBunny.create_connection }
BugBunny::Resource.connection_pool = TEST_POOL

module IntegrationHelper
  def self.rabbitmq_available?
    # Intento de conexión TCP cruda para fail-fast
    socket = TCPSocket.new(BugBunny.configuration.host, 5672)
    socket.close
    true
  rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT, SocketError
    false
  end

  # Helper para levantar un BugBunny::Consumer real en un hilo
  def with_running_worker(queue:, exchange:, exchange_type: 'topic', routing_key: '#')
    conn = BugBunny.create_connection
    
    worker_thread = Thread.new do
      # 1. Asegurar topología: Creamos el exchange explícitamente antes de bindear
      ch = conn.create_channel
      ch.exchange_declare(exchange, exchange_type, durable: false, auto_delete: false)
      ch.close

      # 2. Arrancar el Consumer de la gema
      BugBunny::Consumer.subscribe(
        connection: conn,
        queue_name: queue,
        exchange_name: exchange,
        exchange_type: exchange_type,
        routing_key: routing_key,
        block: true
      )
    rescue => e
      puts "❌ WORKER CRASHED: #{e.message}"
      puts e.backtrace.join("\n")
    end

    # Esperar a que arranque (RabbitMQ necesita unos ms para bindear)
    sleep 0.5 
    
    yield

  ensure
    # Limpieza: Matar conexión y hilo para no dejar zombies
    conn&.close
    worker_thread&.kill
    # Pequeña pausa para permitir que el hilo muera
    sleep 0.1
  end

  # Helper para Nivel 2: Espía crudo (sin BugBunny Consumer)
  def with_spy_worker(queue:, exchange:, exchange_type: 'topic', routing_key: '#')
    captured_messages = Thread::Queue.new
    conn = BugBunny.create_connection
    
    worker_thread = Thread.new do
      ch = conn.create_channel
      x = ch.exchange_declare(exchange, exchange_type, durable: false)
      q = ch.queue(queue, auto_delete: true)
      q.bind(x, routing_key: routing_key)

      q.subscribe(block: true) do |delivery, props, body|
        captured_messages << { 
          body: body, 
          routing_key: delivery.routing_key,
          headers: props.headers 
        }
      end
    end

    sleep 0.5
    yield(captured_messages)
  ensure
    conn&.close
    worker_thread&.kill
  end
end
