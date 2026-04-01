# frozen_string_literal: true

require 'spec_helper'
require 'support/bunny_mocks'

RSpec.describe BugBunny::Consumer do
  include BunnyMocks

  let(:channel)    { BunnyMocks::FakeChannel.new(true) }
  let(:connection) { BunnyMocks::FakeConnection.new(true, channel) }
  let(:consumer)   { described_class.new(connection) }

  let(:fake_session) do
    session = instance_double(BugBunny::Session)
    allow(session).to receive(:exchange).and_return(double('exchange'))
    allow(session).to receive(:queue).and_return(fake_queue)
    allow(session).to receive(:close)
    session
  end

  let(:fake_queue) do
    q = double('queue')
    allow(q).to receive(:bind)
    allow(q).to receive(:subscribe)
    q
  end

  before do
    consumer.instance_variable_set(:@session, fake_session)
  end

  describe '#shutdown' do
    it 'detiene el health timer' do
      timer = instance_double(Concurrent::TimerTask)
      expect(timer).to receive(:shutdown)

      consumer.instance_variable_set(:@health_timer, timer)
      consumer.shutdown

      expect(consumer.instance_variable_get(:@health_timer)).to be_nil
    end

    it 'es idempotente si no hay timer activo' do
      consumer.instance_variable_set(:@health_timer, nil)
      expect { consumer.shutdown }.not_to raise_error
    end

    it 'cierra la sesión' do
      expect(fake_session).to receive(:close)
      consumer.shutdown
    end
  end

  describe '#subscribe' do
    it 'llama a shutdown en el ensure al salir normalmente' do
      shutdown_called = false
      consumer.define_singleton_method(:shutdown) { shutdown_called = true }

      consumer.subscribe(
        queue_name:    'q',
        exchange_name: 'x',
        routing_key:   '#',
        block:         false
      )

      expect(shutdown_called).to be(true)
    end

    it 'llama a shutdown aunque subscribe falle con max_reconnect_attempts=1' do
      shutdown_called = false
      consumer.define_singleton_method(:shutdown) { shutdown_called = true }

      allow(fake_session).to receive(:exchange).and_raise(RuntimeError, 'boom')
      BugBunny.configuration.max_reconnect_attempts = 1

      expect do
        consumer.subscribe(
          queue_name:    'q',
          exchange_name: 'x',
          routing_key:   '#',
          block:         false
        )
      end.to raise_error(RuntimeError)

      expect(shutdown_called).to be(true)
    ensure
      BugBunny.configuration.max_reconnect_attempts = nil
    end
  end
end
