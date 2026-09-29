# frozen_string_literal: true

require 'spec_helper'
require 'support/integration_helper'

module DrainSpec
  # Controller que sólo cuenta cuántas veces se lo invocó.
  class PingController < BugBunny::Controller
    def self.handled_count
      @handled_count ||= Concurrent::AtomicFixnum.new(0)
    end

    def index
      self.class.handled_count.increment
      render status: 200, json: { pong: true }
    end
  end
end

RSpec.describe 'Consumer.drain', :integration do
  let(:queue_name)    { unique('drain_q') }
  let(:exchange_name) { unique('drain_x') }
  let(:client)        { BugBunny::Client.new(pool: TEST_POOL) }
  let(:admin_connection) { BugBunny.create_connection }

  # Durable y no exclusiva: drain declara la cola con su propia conexión, y RabbitMQ 4
  # rechaza las colas no durables y no exclusivas.
  let(:queue_opts) { { durable: true, exclusive: false, auto_delete: false } }

  let(:drain_args) do
    { queue_name: queue_name, exchange_name: exchange_name, exchange_type: 'topic',
      routing_key: 'ping', queue_opts: queue_opts }
  end

  before do
    DrainSpec::PingController.handled_count.value = 0
    BugBunny.configure do |config|
      config.controller_namespace = 'DrainSpec'
      config.drain_idle_timeout = 1
      config.drain_poll_interval = 0.05
    end

    admin_channel = admin_connection.create_channel
    effective_exchange_opts = BugBunny::Session::DEFAULT_EXCHANGE_OPTIONS.merge(BugBunny.configuration.exchange_options)
    exchange = admin_channel.topic(exchange_name, effective_exchange_opts)
    admin_channel.queue(queue_name, queue_opts).bind(exchange, routing_key: 'ping')
  end

  after do
    BugBunny.configure do |config|
      config.controller_namespace = 'BugBunny::Controllers'
      config.drain_idle_timeout = 5
      config.drain_poll_interval = 0.1
    end

    cleanup_channel = admin_connection.create_channel
    cleanup_channel.queue_delete(queue_name)
    cleanup_channel.exchange_delete(exchange_name)
    admin_connection.close
  end

  def publish_ping
    client.publish('ping', method: :get, exchange: exchange_name, exchange_type: 'topic', routing_key: 'ping')
  end

  def passive_queue
    admin_connection.create_channel.queue(queue_name, queue_opts.merge(passive: true))
  end

  def messages_in_queue
    passive_queue.message_count
  end

  # La conexión es del llamador: drain cierra su canal, no la conexión.
  def drain
    connection = BugBunny.create_connection
    BugBunny::Consumer.drain(connection: connection, **drain_args)
  ensure
    connection&.close
  end

  it 'procesa todos los mensajes encolados, los ack-ea y retorna cuántos fueron' do
    BugBunny.configure { |config| config.channel_prefetch = 3 }
    5.times { publish_ping }
    sleep 0.3

    expect(drain).to eq(5)
    expect(DrainSpec::PingController.handled_count.value).to eq(5)
    expect(messages_in_queue).to eq(0)
  ensure
    BugBunny.configure { |config| config.channel_prefetch = 1 }
  end

  it 'con la cola vacía retorna 0 sin esperar la ventana de inactividad' do
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    expect(drain).to eq(0)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at).to be < 1
  end

  # Criterio 5: shutdown corre al volver y cierra el canal. Se mira el canal y no el
  # `consumer_count`: ése queda en 0 por el `cancel` aunque falte el `ensure shutdown`, así
  # que un test sobre él pasaría con el defecto intacto. El canal se toma antes: es el mismo
  # que después usa drain.
  it 'cierra su canal al volver, con la cola vacía y con mensajes' do
    [0, 2].each do |pending|
      pending.times { publish_ping }
      sleep 0.3 if pending.positive?

      connection = BugBunny.create_connection
      consumer = BugBunny::Consumer.new(connection)
      channel = consumer.session.channel

      consumer.drain(**drain_args)

      expect(channel).not_to be_open, "con #{pending} mensajes el canal quedó abierto"
    ensure
      connection&.close
    end
  end

  # Review de #65: un middleware que levanta dejaba la entrega sin ack ni reject; con
  # prefetch 1 trababa la cola y drain volvía "con éxito" sin haber sacado nada.
  it 'una entrega cuyo middleware levanta sale de la cola y no traba el prefetch' do
    exploding = Class.new(BugBunny::ConsumerMiddleware::Base) do
      def call(*)
        raise 'middleware roto'
      end
    end
    BugBunny.consumer_middlewares.use exploding
    BugBunny.configure { |config| config.channel_prefetch = 1 }
    3.times { publish_ping }
    sleep 0.3

    expect(drain).to eq(3)
    expect(messages_in_queue).to eq(0)
    expect(DrainSpec::PingController.handled_count.value).to eq(0)
  ensure
    BugBunny.configuration.instance_variable_set(:@consumer_middlewares, BugBunny::ConsumerMiddleware::Stack.new)
    BugBunny.configure { |config| config.channel_prefetch = 1 }
  end

  # Review de #65: la guarda `unless settled` de `settle_failed_delivery`. Si el error
  # llega DESPUÉS del ack, rechazar el tag ya confirmado hace que el broker cierre el
  # canal; sin la guarda, drain terminaba en Timeout::Error con mensajes en la cola.
  it 'un middleware que levanta después del ack no rechaza la entrega ya resuelta' do
    after_ack = Class.new(BugBunny::ConsumerMiddleware::Base) do
      def call(*args)
        @app.call(*args)
        raise 'después del ack'
      end
    end
    BugBunny.consumer_middlewares.use after_ack
    BugBunny.configure { |config| config.channel_prefetch = 1 }
    3.times { publish_ping }
    sleep 0.3

    expect(drain).to eq(3)
    expect(messages_in_queue).to eq(0)
    expect(DrainSpec::PingController.handled_count.value).to eq(3)
  ensure
    BugBunny.configuration.instance_variable_set(:@consumer_middlewares, BugBunny::ConsumerMiddleware::Stack.new)
    BugBunny.configure { |config| config.channel_prefetch = 1 }
  end

  it 'procesa en la misma vuelta un mensaje que llega dentro de la ventana de inactividad' do
    publish_ping
    sleep 0.3

    drain_thread = Thread.new { drain }
    sleep 0.5
    publish_ping

    expect(drain_thread.value).to eq(2)
    expect(messages_in_queue).to eq(0)
  end
end
