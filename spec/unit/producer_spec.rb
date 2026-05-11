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

  describe '#confirmed' do
    let(:fake_exchange) { double('exchange') }

    let(:mock_channel) do
      ch = double('channel')
      allow(ch).to receive(:publish)
      allow(ch).to receive(:open?).and_return(true)
      allow(ch).to receive(:wait_for_confirms).and_return(true)
      allow(ch).to receive(:nacked_set).and_return(Set.new)
      ch
    end

    let(:mock_session) do
      s = instance_double(BugBunny::Session)
      allow(s).to receive(:exchange).and_return(fake_exchange)
      allow(s).to receive(:channel).and_return(mock_channel)
      s
    end

    let(:confirmed_producer) { described_class.new(mock_session) }

    before do
      allow(confirmed_producer).to receive(:safe_log) do |level, event, **kwargs|
        logged_events << { level: level, event: event, kwargs: kwargs }
      end
      allow(fake_exchange).to receive(:publish)
    end

    def build_request
      req = BugBunny::Request.new('acct.start')
      req.exchange = 'acct_x'
      req.method = :post
      req.body = { tenant: 42 }
      req
    end

    it 'retorna { status: 202 } cuando el broker confirma' do
      result = confirmed_producer.confirmed(build_request)

      expect(result).to eq('status' => 202, 'body' => nil)
    end

    it 'invoca wait_for_confirms en el canal' do
      confirmed_producer.confirmed(build_request)

      expect(mock_channel).to have_received(:wait_for_confirms)
    end

    it 'publica con mandatory: true cuando el request lo activa' do
      req = build_request
      req.mandatory = true

      confirmed_producer.confirmed(req)

      expect(fake_exchange).to have_received(:publish).with(
        anything,
        hash_including(mandatory: true, routing_key: 'acct.start')
      )
    end

    it 'NO logea producer.confirms_nacked cuando wait_for_confirms devuelve true' do
      confirmed_producer.confirmed(build_request)

      nack_event = logged_events.find { |e| e[:event] == 'producer.confirms_nacked' }
      expect(nack_event).to be_nil
    end

    context 'cuando el broker NACKea (wait_for_confirms devuelve false)' do
      before do
        allow(mock_channel).to receive(:wait_for_confirms).and_return(false)
        allow(mock_channel).to receive(:nacked_set).and_return(Set.new([1, 2]))
      end

      it 'levanta BugBunny::PublishNacked por default (config.nack_raise = true)' do
        expect { confirmed_producer.confirmed(build_request) }.to raise_error(BugBunny::PublishNacked) do |err|
          expect(err.path).to eq('acct.start')
          expect(err.nacked_count).to eq(2)
        end
      end

      it 'logea producer.confirms_nacked antes de levantar' do
        expect { confirmed_producer.confirmed(build_request) }.to raise_error(BugBunny::PublishNacked)

        nack_event = logged_events.find { |e| e[:event] == 'producer.confirms_nacked' }
        expect(nack_event).not_to be_nil
        expect(nack_event[:kwargs]).to include(count: 2, path: 'acct.start')
      end

      it 'no levanta si el request override `nack_raise = false`' do
        req = build_request
        req.nack_raise = false

        result = confirmed_producer.confirmed(req)

        expect(result).to eq('status' => 202, 'body' => nil)
        expect(logged_events.find { |e| e[:event] == 'producer.confirms_nacked' }).not_to be_nil
      end

      it 'no levanta si la configuración global tiene `nack_raise = false`' do
        allow(BugBunny.configuration).to receive(:nack_raise).and_return(false)

        result = confirmed_producer.confirmed(build_request)

        expect(result).to eq('status' => 202, 'body' => nil)
      end

      it 'el override per-request gana sobre la configuración global' do
        allow(BugBunny.configuration).to receive(:nack_raise).and_return(false)
        req = build_request
        req.nack_raise = true

        expect { confirmed_producer.confirmed(req) }.to raise_error(BugBunny::PublishNacked)
      end
    end

    it 'levanta BugBunny::RequestTimeout si wait_for_confirms excede confirm_timeout' do
      allow(mock_channel).to receive(:wait_for_confirms) {
        sleep 1
        true
      }

      req = build_request
      req.confirm_timeout = 0.05

      expect { confirmed_producer.confirmed(req) }.to raise_error(BugBunny::RequestTimeout, /Timeout/)
    end

    it 'envuelve errores del canal como BugBunny::CommunicationError' do
      allow(mock_channel).to receive(:wait_for_confirms).and_raise(StandardError, 'boom')

      expect { confirmed_producer.confirmed(build_request) }
        .to raise_error(BugBunny::CommunicationError, /boom/)
    end

    it 'propaga BugBunny::Error sin envolver' do
      allow(fake_exchange).to receive(:publish).and_raise(BugBunny::CommunicationError, 'chan dead')

      expect { confirmed_producer.confirmed(build_request) }
        .to raise_error(BugBunny::CommunicationError, 'chan dead')
    end
  end
end
