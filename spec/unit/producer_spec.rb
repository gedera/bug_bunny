# frozen_string_literal: true

require 'spec_helper'
require 'support/bunny_mocks'

RSpec.describe BugBunny::Producer do
  include BunnyMocks

  let(:channel)    { BunnyMocks::FakeChannel.new(true) }
  let(:connection) { BunnyMocks::FakeConnection.new(true, channel) }
  let(:session)    { BugBunny::Session.new(connection) }
  let(:producer)   { described_class.new(session) }

  let(:logged_events) { [] }

  before do
    allow(producer).to receive(:safe_log) do |level, event, **kwargs|
      logged_events << { level: level, event: event, kwargs: kwargs }
    end
  end

  describe 'OTel messaging semantic conventions en logs' do
    describe '#fire — log events incluyen campos OTel' do
      it 'producer.publish incluye otel_fields con operation=publish' do
        request = BugBunny::Request.new('users')
        request.exchange = 'users_x'
        request.method = :post
        request.body = { name: 'test' }

        fake_exchange = double('exchange')
        allow(session).to receive(:exchange).and_return(fake_exchange)
        allow(fake_exchange).to receive(:publish)

        producer.fire(request)

        publish_event = logged_events.find { |e| e[:event] == 'producer.publish' }
        expect(publish_event).not_to be_nil
        expect(publish_event[:kwargs]).to include(
          method: 'POST',
          path: 'users',
          messaging_system: 'rabbitmq',
          messaging_operation: 'publish',
          messaging_destination_name: 'users_x',
          messaging_routing_key: 'users'
        )
      end

      it 'producer.publish incluye messaging_message_id cuando hay correlation_id' do
        request = BugBunny::Request.new('users/42')
        request.exchange = 'users_x'
        request.correlation_id = 'corr-xyz-789'
        request.method = :get

        fake_exchange = double('exchange')
        allow(session).to receive(:exchange).and_return(fake_exchange)
        allow(fake_exchange).to receive(:publish)

        producer.fire(request)

        publish_event = logged_events.find { |e| e[:event] == 'producer.publish' }
        expect(publish_event[:kwargs]).to include(
          messaging_message_id: 'corr-xyz-789'
        )
      end

      it 'producer.publish omite messaging_message_id cuando no hay correlation_id' do
        request = BugBunny::Request.new('users')
        request.exchange = 'users_x'
        request.method = :post

        fake_exchange = double('exchange')
        allow(session).to receive(:exchange).and_return(fake_exchange)
        allow(fake_exchange).to receive(:publish)

        producer.fire(request)

        publish_event = logged_events.find { |e| e[:event] == 'producer.publish' }
        expect(publish_event[:kwargs]).not_to have_key(:messaging_message_id)
      end

      it 'producer.publish_detail incluye messaging_destination_name' do
        request = BugBunny::Request.new('users')
        request.exchange = 'events_x'
        request.method = :post

        fake_exchange = double('exchange')
        allow(session).to receive(:exchange).and_return(fake_exchange)
        allow(fake_exchange).to receive(:publish)

        producer.fire(request)

        detail_event = logged_events.find { |e| e[:event] == 'producer.publish_detail' }
        expect(detail_event).not_to be_nil
        expect(detail_event[:kwargs]).to include(
          messaging_destination_name: 'events_x'
        )
      end
    end

    describe '#rpc — log events incluyen campos OTel' do
      let(:fake_exchange) { double('exchange') }
      let(:mock_channel) do
        ch = double('channel')
        allow(ch).to receive(:publish)
        allow(ch).to receive(:basic_consume)
        allow(ch).to receive(:open?).and_return(true)
        ch
      end

      let(:mock_session) do
        s = instance_double(BugBunny::Session)
        allow(s).to receive(:exchange).and_return(fake_exchange)
        allow(s).to receive(:channel).and_return(mock_channel)
        s
      end

      let(:rpc_producer) { described_class.new(mock_session) }

      before do
        allow(rpc_producer).to receive(:safe_log) do |level, event, **kwargs|
          logged_events << { level: level, event: event, kwargs: kwargs }
        end
        allow(fake_exchange).to receive(:publish)
      end

      it 'producer.rpc_waiting incluye messaging_message_id' do
        request = BugBunny::Request.new('users')
        request.exchange = 'users_x'
        request.method = :get

        allow(rpc_producer).to receive(:ensure_reply_listener!)

        ivar = Concurrent::IVar.new
        allow(Concurrent::IVar).to receive(:new).and_return(ivar)
        allow(rpc_producer).to receive(:sleep)

        request.correlation_id = 'test-cid'

        rpc_producer.instance_variable_get(:@pending_requests)['test-cid'] = ivar

        thread = Thread.new do
          sleep 0.05
          ivar.set({ body: '{"ok":true}', headers: {} })
        end
        thread.join

        rpc_producer.rpc(request)

        waiting_event = logged_events.find { |e| e[:event] == 'producer.rpc_waiting' }
        expect(waiting_event).not_to be_nil
        expect(waiting_event[:kwargs]).to include(
          messaging_message_id: 'test-cid',
          timeout_s: an_instance_of(Integer)
        )
      end

      it 'producer.rpc_response_received incluye otel_fields con operation=receive' do
        request = BugBunny::Request.new('users')
        request.exchange = 'users_x'
        request.method = :get

        allow(rpc_producer).to receive(:ensure_reply_listener!)

        ivar = Concurrent::IVar.new
        allow(Concurrent::IVar).to receive(:new).and_return(ivar)
        allow(rpc_producer).to receive(:sleep)

        request.correlation_id = 'corr-reply-test'

        rpc_producer.instance_variable_get(:@pending_requests)['corr-reply-test'] = ivar

        thread = Thread.new { ivar.set({ body: '{"ok":true}', headers: {} }) }
        thread.join(0.1)

        rpc_producer.rpc(request)

        response_event = logged_events.find { |e| e[:event] == 'producer.rpc_response_received' }
        expect(response_event).not_to be_nil
        expect(response_event[:kwargs]).to include(
          messaging_system: 'rabbitmq',
          messaging_operation: 'receive',
          messaging_message_id: 'corr-reply-test'
        )
      end
    end
  end
end
