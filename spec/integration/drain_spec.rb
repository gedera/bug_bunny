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

  def messages_in_queue
    admin_connection.create_channel.queue(queue_name, queue_opts.merge(passive: true)).message_count
  end

  def drain
    BugBunny::Consumer.drain(connection: BugBunny.create_connection, **drain_args)
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
