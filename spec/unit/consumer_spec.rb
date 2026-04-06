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
    allow(session).to receive(:channel).and_return(channel)
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

  describe 'OTel messaging semantic conventions en logs' do
    let(:mock_channel) do
      ch = double('channel')
      allow(ch).to receive(:reject)
      allow(ch).to receive(:ack)
      allow(ch).to receive(:open?).and_return(true)
      default_ex = double('default_exchange')
      allow(default_ex).to receive(:publish)
      allow(ch).to receive(:default_exchange).and_return(default_ex)
      ch
    end

    let(:mock_session) do
      s = instance_double(BugBunny::Session)
      allow(s).to receive(:exchange).and_return(double('exchange'))
      allow(s).to receive(:queue).and_return(fake_queue)
      allow(s).to receive(:close)
      allow(s).to receive(:channel).and_return(mock_channel)
      s
    end

    let(:otel_consumer) do
      c = described_class.new(connection)
      c.instance_variable_set(:@session, mock_session)
      c
    end

    let(:delivery_info) do
      double('delivery_info',
             exchange: 'events_x',
             routing_key: 'users.created',
             delivery_tag: 'delivery-tag-1',
             redelivered?: false)
    end

    let(:properties) do
      double('properties',
             type: 'users/show',
             headers: { 'x-http-method' => 'GET' },
             correlation_id: 'corr-abc-123',
             reply_to: 'amq.rabbitmq.reply-to',
             content_type: 'application/json')
    end

    let(:logged_events) { [] }

    before do
      allow(otel_consumer).to receive(:safe_log) do |level, event, **kwargs|
        logged_events << { level: level, event: event, kwargs: kwargs }
      end
      allow(otel_consumer).to receive(:handle_fatal_error)
    end

    describe '#process_message — log events incluyen campos OTel' do
      it 'consumer.message_received incluye otel_fields con operation=process' do
        allow(BugBunny.routes).to receive(:recognize).and_return(
          { controller: 'user', action: 'show', params: {}, namespace: nil }
        )

        controller_class = Class.new(BugBunny::Controller) do
          def show
            render status: 200, json: { ok: true }
          end
        end
        stub_const('BugBunny::Controllers::UserController', controller_class)

        otel_consumer.send(:process_message, delivery_info, properties, '{}')

        received_event = logged_events.find { |e| e[:event] == 'consumer.message_received' }
        expect(received_event).not_to be_nil
        expect(received_event[:kwargs]).to include(
          messaging_system: 'rabbitmq',
          messaging_operation: 'process',
          messaging_destination_name: 'events_x',
          messaging_routing_key: 'users.created',
          messaging_message_id: 'corr-abc-123'
        )
      end

      it 'consumer.message_processed incluye otel_fields con operation=process' do
        allow(BugBunny.routes).to receive(:recognize).and_return(
          { controller: 'user', action: 'show', params: {}, namespace: nil }
        )

        controller_class = Class.new(BugBunny::Controller) do
          def show
            render status: 200, json: { ok: true }
          end
        end
        stub_const('BugBunny::Controllers::UserController', controller_class)

        otel_consumer.send(:process_message, delivery_info, properties, '{}')

        processed_event = logged_events.find { |e| e[:event] == 'consumer.message_processed' }
        expect(processed_event).not_to be_nil
        expect(processed_event[:kwargs]).to include(
          messaging_system: 'rabbitmq',
          messaging_operation: 'process',
          messaging_destination_name: 'events_x',
          messaging_routing_key: 'users.created',
          messaging_message_id: 'corr-abc-123'
        )
      end

      it 'consumer.message_received omite messaging_message_id cuando no hay correlation_id' do
        properties_no_corr = double('properties',
                                    type: 'users/show',
                                    headers: { 'x-http-method' => 'GET' },
                                    correlation_id: nil,
                                    reply_to: nil,
                                    content_type: 'application/json')

        allow(BugBunny.routes).to receive(:recognize).and_return(
          { controller: 'user', action: 'show', params: {}, namespace: nil }
        )

        controller_class = Class.new(BugBunny::Controller) do
          def show
            render status: 200, json: { ok: true }
          end
        end
        stub_const('BugBunny::Controllers::UserController', controller_class)

        otel_consumer.send(:process_message, delivery_info, properties_no_corr, '{}')

        received_event = logged_events.find { |e| e[:event] == 'consumer.message_received' }
        expect(received_event[:kwargs]).not_to have_key(:messaging_message_id)
      end
    end
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
        queue_name: 'q',
        exchange_name: 'x',
        routing_key: '#',
        block: false
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
          queue_name: 'q',
          exchange_name: 'x',
          routing_key: '#',
          block: false
        )
      end.to raise_error(RuntimeError)

      expect(shutdown_called).to be(true)
    ensure
      BugBunny.configuration.max_reconnect_attempts = nil
    end
  end
end
