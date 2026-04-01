# frozen_string_literal: true

require 'timeout'

# Helpers compartidos para specs de integración con RabbitMQ real.
# Incluido automáticamente en todos los specs marcados con :integration.
RSpec.shared_context 'integration helpers' do
  def rabbitmq_available?
    conn = BugBunny.create_connection
    conn.start
    conn.close
    true
  rescue StandardError
    false
  end

  # Levanta un Consumer real en un thread separado y cede el control al bloque.
  # El consumer se detiene al salir del bloque.
  #
  # @param queue [String] nombre de la cola
  # @param exchange [String] nombre del exchange
  # @param exchange_type [String] tipo de exchange
  # @param routing_key [String] routing key de binding
  def with_running_worker(queue:, exchange:, exchange_type: 'topic', routing_key: '#')
    conn = BugBunny.create_connection
    consumer = BugBunny::Consumer.new(conn)

    worker_thread = Thread.new do
      consumer.subscribe(
        queue_name:    queue,
        exchange_name: exchange,
        exchange_type: exchange_type,
        routing_key:   routing_key,
        block:         true
      )
    rescue StandardError => e
      warn "WORKER ERROR: #{e.message}"
    end

    sleep 0.5
    yield
  ensure
    consumer.shutdown rescue nil
    conn&.close rescue nil
    worker_thread&.kill
    sleep 0.1
  end

  # Levanta un worker espía que captura mensajes raw sin procesarlos.
  # Útil para verificar que el mensaje llegó con el routing key y headers correctos.
  #
  # @yieldparam messages [Thread::Queue] cola thread-safe donde llegan los mensajes
  def with_spy_worker(queue:, exchange:, exchange_type: 'topic', routing_key: '#')
    messages = Thread::Queue.new
    conn = BugBunny.create_connection

    worker_thread = Thread.new do
      ch = conn.create_channel
      x  = ch.public_send(exchange_type, exchange, BugBunny.configuration.exchange_options)
      q  = ch.queue(queue, BugBunny.configuration.queue_options)
      q.bind(x, routing_key: routing_key)
      q.subscribe(block: true) do |delivery, props, body|
        messages << { body: body, routing_key: delivery.routing_key, headers: props.headers }
      end
    rescue StandardError => e
      warn "SPY ERROR: #{e.message}"
    end

    sleep 0.5
    yield(messages)
  ensure
    conn&.close rescue nil
    worker_thread&.kill
  end

  # Espera un mensaje de la Queue con timeout.
  def wait_for_message(queue, timeout_sec = 3)
    Timeout.timeout(timeout_sec) { queue.pop }
  rescue Timeout::Error
    raise "Timeout: no llegó ningún mensaje en #{timeout_sec}s"
  end

  # Genera nombres únicos para evitar colisiones entre tests.
  def unique(name)
    "#{name}_#{SecureRandom.hex(4)}"
  end
end
