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

      it 'producer.published incluye duration_s y campos de routing' do
        request = BugBunny::Request.new('users')
        request.exchange = 'users_x'
        request.method = :post
        request.correlation_id = 'corr-1'

        fake_exchange = double('exchange')
        allow(session).to receive(:exchange).and_return(fake_exchange)
        allow(fake_exchange).to receive(:publish)

        producer.fire(request)

        published_event = logged_events.find { |e| e[:event] == 'producer.published' }
        expect(published_event).not_to be_nil
        expect(published_event[:level]).to eq(:info)
        expect(published_event[:kwargs]).to include(
          method: 'POST',
          path: 'users',
          routing_key: 'users',
          messaging_message_id: 'corr-1'
        )
        expect(published_event[:kwargs][:duration_s]).to be_a(Numeric)
        expect(published_event[:kwargs][:duration_s]).to be >= 0
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

      it 'producer.rpc_response_received incluye duration_s total' do
        request = BugBunny::Request.new('users')
        request.exchange = 'users_x'
        request.method = :get

        allow(rpc_producer).to receive(:ensure_reply_listener!)

        ivar = Concurrent::IVar.new
        allow(Concurrent::IVar).to receive(:new).and_return(ivar)

        request.correlation_id = 'corr-dur'
        rpc_producer.instance_variable_get(:@pending_requests)['corr-dur'] = ivar

        Thread.new { ivar.set({ body: '{"ok":true}', headers: {} }) }.join(0.1)

        rpc_producer.rpc(request)

        response_event = logged_events.find { |e| e[:event] == 'producer.rpc_response_received' }
        expect(response_event[:kwargs][:duration_s]).to be_a(Numeric)
        expect(response_event[:kwargs][:duration_s]).to be >= 0
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
      # Return registry stubs: tests que activan `mandatory: true` con `return_raise`
      # default invocan estos hooks. Devolvemos un event/slot vacío (no return).
      allow(s).to receive(:register_return_listener) do |_cid|
        [Concurrent::Event.new, { event: Concurrent::Event.new, info: nil }]
      end
      allow(s).to receive(:unregister_return_listener)
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

    it 'logea producer.confirmed con publish_duration_s, confirm_duration_s y duration_s total' do
      confirmed_producer.confirmed(build_request)

      ev = logged_events.find { |e| e[:event] == 'producer.confirmed' }
      expect(ev).not_to be_nil
      expect(ev[:level]).to eq(:info)
      expect(ev[:kwargs]).to include(method: 'POST', path: 'acct.start', routing_key: 'acct.start')
      expect(ev[:kwargs][:publish_duration_s]).to be_a(Numeric)
      expect(ev[:kwargs][:confirm_duration_s]).to be_a(Numeric)
      expect(ev[:kwargs][:duration_s]).to be_a(Numeric)
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

    it 'envuelve Bunny::Exception del canal como BugBunny::CommunicationError' do
      allow(mock_channel).to receive(:wait_for_confirms)
        .and_raise(Bunny::ChannelAlreadyClosed.new('boom', double(id: 1)))

      expect { confirmed_producer.confirmed(build_request) }
        .to raise_error(BugBunny::CommunicationError, /boom/)
    end

    it 'no traga errores genéricos de Ruby (rescue es Bunny::Exception, no StandardError)' do
      allow(mock_channel).to receive(:wait_for_confirms).and_raise(NoMethodError, 'bug interno')

      expect { confirmed_producer.confirmed(build_request) }
        .to raise_error(NoMethodError, 'bug interno')
    end

    it 'propaga BugBunny::Error sin envolver' do
      allow(fake_exchange).to receive(:publish).and_raise(BugBunny::CommunicationError, 'chan dead')

      expect { confirmed_producer.confirmed(build_request) }
        .to raise_error(BugBunny::CommunicationError, 'chan dead')
    end

    describe 'return_raise (basic.return + mandatory)' do
      # Dispara el `basic.return` desde el reader-thread simulado. El stub de
      # wait_for_confirms invoca este lambda *antes* de retornar true, simulando
      # el orden AMQP wire: return precede al ack.
      def stub_return_during_wait(producer, return_info)
        allow(mock_channel).to receive(:wait_for_confirms) do
          props = double('properties', correlation_id: producer_pending_cid(producer))
          producer.instance_variable_get(:@session)
                  .send(:handle_broker_return, return_info, props, 'payload')
          true
        end
      end

      def producer_pending_cid(producer)
        session = producer.instance_variable_get(:@session)
        registry = session.instance_variable_get(:@pending_returns)
        cids = []
        registry.each_pair { |cid, _slot| cids << cid }
        cids.first
      end

      let(:return_info) do
        Struct.new(:reply_code, :reply_text, :exchange, :routing_key)
              .new(312, 'NO_ROUTE', 'acct_x', 'acct.unbound')
      end

      let(:real_session) do
        s = BugBunny::Session.new(BunnyMocks::FakeConnection.new(true, mock_channel))
        allow(s).to receive(:channel).and_return(mock_channel)
        allow(s).to receive(:exchange).and_return(fake_exchange)
        s
      end

      let(:return_producer) do
        p = described_class.new(real_session)
        allow(p).to receive(:safe_log) do |level, event, **kwargs|
          logged_events << { level: level, event: event, kwargs: kwargs }
        end
        p
      end

      before do
        BugBunny.configuration.on_return = nil
      end

      after do
        BugBunny.configuration.on_return = nil
      end

      def build_mandatory_request
        req = BugBunny::Request.new('acct.start')
        req.exchange = 'acct_x'
        req.method = :post
        req.body = { tenant: 42 }
        req.mandatory = true
        req
      end

      it 'levanta PublishUnroutable cuando llega basic.return + ack y mandatory:true (default)' do
        stub_return_during_wait(return_producer, return_info)

        req = build_mandatory_request

        expect { return_producer.confirmed(req) }.to raise_error(BugBunny::PublishUnroutable) do |err|
          expect(err.path).to eq('acct.start')
          expect(err.exchange).to eq('acct_x')
          expect(err.routing_key).to eq('acct.unbound')
          expect(err.reply_code).to eq(312)
          expect(err.reply_text).to eq('NO_ROUTE')
          expect(err.correlation_id).to eq(req.correlation_id)
        end
      end

      it 'logea producer.publish_unroutable antes de levantar' do
        stub_return_during_wait(return_producer, return_info)

        expect { return_producer.confirmed(build_mandatory_request) }
          .to raise_error(BugBunny::PublishUnroutable)

        ev = logged_events.find { |e| e[:event] == 'producer.publish_unroutable' }
        expect(ev).not_to be_nil
        expect(ev[:level]).to eq(:warn)
        expect(ev[:kwargs]).to include(
          path: 'acct.start',
          exchange: 'acct_x',
          routing_key: 'acct.unbound',
          reply_code: 312
        )
      end

      it 'auto-asigna correlation_id cuando falta y return_raise está activo' do
        stub_return_during_wait(return_producer, return_info)
        req = build_mandatory_request
        expect(req.correlation_id).to be_nil

        expect { return_producer.confirmed(req) }.to raise_error(BugBunny::PublishUnroutable)
        expect(req.correlation_id).to be_a(String)
        expect(req.correlation_id).not_to be_empty
      end

      it 'limpia el listener del registry tras un return (no leak)' do
        stub_return_during_wait(return_producer, return_info)
        req = build_mandatory_request

        expect { return_producer.confirmed(req) }.to raise_error(BugBunny::PublishUnroutable)

        registry = real_session.instance_variable_get(:@pending_returns)
        expect(registry.size).to eq(0)
      end

      it 'limpia el listener del registry tras un ack normal sin return' do
        # mock_channel.wait_for_confirms default ya devuelve true sin disparar return
        req = build_mandatory_request
        result = return_producer.confirmed(req)

        expect(result).to eq('status' => 202, 'body' => nil)
        registry = real_session.instance_variable_get(:@pending_returns)
        expect(registry.size).to eq(0)
      end

      it 'limpia el listener del registry tras timeout en wait_for_confirms' do
        allow(mock_channel).to receive(:wait_for_confirms) {
          sleep 1
          true
        }

        req = build_mandatory_request
        req.confirm_timeout = 0.05

        expect { return_producer.confirmed(req) }.to raise_error(BugBunny::RequestTimeout)
        registry = real_session.instance_variable_get(:@pending_returns)
        expect(registry.size).to eq(0)
      end

      it 'no levanta cuando el request override `return_raise: false`' do
        # No stub de return — el listener no se registra siquiera.
        req = build_mandatory_request
        req.return_raise = false

        result = return_producer.confirmed(req)
        expect(result).to eq('status' => 202, 'body' => nil)
        # Sin listener registrado (flag off) → no hubo set up
        registry = real_session.instance_variable_get(:@pending_returns)
        expect(registry.size).to eq(0)
      end

      it 'no levanta cuando la config global tiene return_raise=false (aunque mandatory esté on)' do
        allow(BugBunny.configuration).to receive(:return_raise).and_return(false)

        req = build_mandatory_request
        result = return_producer.confirmed(req)

        expect(result).to eq('status' => 202, 'body' => nil)
      end

      it 'override per-request gana sobre la config global' do
        allow(BugBunny.configuration).to receive(:return_raise).and_return(false)
        stub_return_during_wait(return_producer, return_info)

        req = build_mandatory_request
        req.return_raise = true

        expect { return_producer.confirmed(req) }.to raise_error(BugBunny::PublishUnroutable)
      end

      it 'flag inerte cuando mandatory:false aunque return_raise=true' do
        req = BugBunny::Request.new('acct.start')
        req.exchange = 'acct_x'
        req.method = :post
        req.body = { tenant: 42 }
        req.mandatory = false
        req.return_raise = true

        result = return_producer.confirmed(req)
        expect(result).to eq('status' => 202, 'body' => nil)
        registry = real_session.instance_variable_get(:@pending_returns)
        expect(registry.size).to eq(0)
      end

      it 'invoca el callback global on_return antes de levantar PublishUnroutable' do
        captured = nil
        BugBunny.configuration.on_return = lambda { |ri, _props, _body|
          captured = { rk: ri.routing_key }
        }

        stub_return_during_wait(return_producer, return_info)

        expect { return_producer.confirmed(build_mandatory_request) }
          .to raise_error(BugBunny::PublishUnroutable)
        expect(captured).to eq(rk: 'acct.unbound')
      end

      it 'levanta PublishUnroutable aunque el user_cb on_return explote' do
        BugBunny.configuration.on_return = ->(_, _, _) { raise 'boom in user cb' }
        stub_return_during_wait(return_producer, return_info)

        expect { return_producer.confirmed(build_mandatory_request) }
          .to raise_error(BugBunny::PublishUnroutable)
      end
    end
  end
end
