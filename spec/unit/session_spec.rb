# frozen_string_literal: true

require 'spec_helper'
require 'support/bunny_mocks'

RSpec.describe BugBunny::Session do
  include BunnyMocks

  let(:channel)    { BunnyMocks::FakeChannel.new(false).tap { |c| c.open = true } }
  let(:connection) { BunnyMocks::FakeConnection.new(true, channel) }
  let(:session)    { described_class.new(connection) }

  describe '#channel' do
    context 'cuando el canal está abierto' do
      it 'retorna el canal existente sin crear uno nuevo (fast path)' do
        first  = session.channel
        second = session.channel
        expect(second).to be(first)
      end
    end

    context 'cuando el canal está cerrado' do
      it 'crea un canal nuevo' do
        session.channel # inicializa

        new_channel = BunnyMocks::FakeChannel.new(true)
        session.instance_variable_get(:@channel).open = false
        connection.channel_to_return = new_channel

        expect(session.channel).to be(new_channel)
      end
    end

    context 'con múltiples threads simultáneos' do
      it 'llama a create_channel! exactamente una vez aunque varios threads compitan' do
        fresh_session = described_class.new(connection)
        create_count  = Concurrent::AtomicFixnum.new(0)

        fresh_session.define_singleton_method(:create_channel!) do
          create_count.increment
          super()
        end

        threads = 10.times.map { Thread.new { fresh_session.channel } }
        threads.each(&:join)

        expect(create_count.value).to eq(1)
      end
    end

    context 'cuando la conexión está cerrada' do
      it 'reconecta transparentemente' do
        closed_conn = BunnyMocks::FakeConnection.new(false, channel)
        s = described_class.new(closed_conn)

        s.channel

        expect(closed_conn.open?).to be(true)
      end

      it 'lanza CommunicationError si la reconexión falla' do
        bad_conn = BunnyMocks::FakeConnection.new(false, channel)
        bad_conn.define_singleton_method(:start) { raise RuntimeError, 'refused' }

        s = described_class.new(bad_conn)

        expect { s.channel }.to raise_error(BugBunny::CommunicationError)
      end
    end
  end

  describe '#on_return handler' do
    let(:return_info) do
      Struct.new(:reply_code, :reply_text, :exchange, :routing_key)
            .new(312, 'NO_ROUTE', 'evt_x', 'unbound.key')
    end
    let(:properties) { double('properties') }
    let(:body) { '{"a":1}' }

    before do
      # Logger en memoria para inspeccionar el default
      @log_io = StringIO.new
      BugBunny.configuration.logger = Logger.new(@log_io)
      BugBunny.configuration.on_return = nil
    end

    after do
      BugBunny.configuration.logger = Logger.new($stdout).tap { |l| l.level = Logger::INFO }
      BugBunny.configuration.on_return = nil
    end

    it 'se registra sobre el exchange cuando publisher_confirms está activo' do
      exchange = session.exchange(name: 'evt_x', type: 'topic')

      expect { exchange.fire_return(return_info, properties, body) }.not_to raise_error
    end

    it 'registra una sola vez por nombre de exchange' do
      first  = session.exchange(name: 'evt_x', type: 'topic')
      second = session.exchange(name: 'evt_x', type: 'topic')

      expect(second).to be(first)
      expect(session.instance_variable_get(:@configured_returns)).to include('evt_x' => true)
    end

    it 'NO se registra cuando publisher_confirms está desactivado' do
      fresh_channel = BunnyMocks::FakeChannel.new(true)
      fresh_conn = BunnyMocks::FakeConnection.new(true, fresh_channel)
      no_confirms = described_class.new(fresh_conn, publisher_confirms: false)
      exchange = no_confirms.exchange(name: 'evt_x', type: 'topic')

      expect(exchange.instance_variable_get(:@on_return_handler)).to be_nil
    end

    it 'NO se registra sobre el default exchange (name vacío)' do
      default = session.exchange # name nil → default_exchange

      expect(default.instance_variable_get(:@on_return_handler)).to be_nil
    end

    it 'invoca el callback de Configuration#on_return cuando está definido' do
      received = nil
      BugBunny.configuration.on_return = lambda { |ri, props, b|
        received = { rk: ri.routing_key, props: props, body: b }
      }

      exchange = session.exchange(name: 'evt_x', type: 'topic')
      exchange.fire_return(return_info, properties, body)

      expect(received).to include(rk: 'unbound.key', body: '{"a":1}')
    end

    it 'logea session.broker_return como :warn cuando no hay callback' do
      exchange = session.exchange(name: 'evt_x', type: 'topic')
      exchange.fire_return(return_info, properties, body)

      log = @log_io.string
      expect(log).to include('event=session.broker_return')
      expect(log).to include('reply_code=312')
      expect(log).to include('routing_key=unbound.key')
      expect(log).to include('body_size=7')
    end

    it 'no propaga excepciones del callback de usuario' do
      BugBunny.configuration.on_return = ->(_, _, _) { raise 'boom' }

      exchange = session.exchange(name: 'evt_x', type: 'topic')

      expect { exchange.fire_return(return_info, properties, body) }.not_to raise_error
      expect(@log_io.string).to include('event=session.on_return_failed')
    end
  end

  describe '#register_return_listener / #unregister_return_listener' do
    let(:properties_for) do
      ->(cid) { double('properties', correlation_id: cid) }
    end

    let(:return_info) do
      Struct.new(:reply_code, :reply_text, :exchange, :routing_key)
            .new(312, 'NO_ROUTE', 'evt_x', 'rk')
    end

    before do
      BugBunny.configuration.on_return = nil
    end

    after do
      BugBunny.configuration.on_return = nil
    end

    it 'devuelve un Concurrent::Event y un slot que se setean al disparar el return' do
      event, slot = session.register_return_listener('corr-1')

      expect(event).to be_a(Concurrent::Event)
      expect(slot[:info]).to be_nil

      session.send(:handle_broker_return, return_info, properties_for.call('corr-1'), 'payload')

      expect(event.set?).to be(true)
      expect(slot[:info]).to eq(return_info)
    end

    it 'no toca otros listeners cuando llega un return de otro correlation_id' do
      event_a, slot_a = session.register_return_listener('corr-A')
      event_b, slot_b = session.register_return_listener('corr-B')

      session.send(:handle_broker_return, return_info, properties_for.call('corr-A'), 'p')

      expect(event_a.set?).to be(true)
      expect(slot_a[:info]).to eq(return_info)
      expect(event_b.set?).to be(false)
      expect(slot_b[:info]).to be_nil
    end

    it 'ignora returns sin correlation_id en properties' do
      event, slot = session.register_return_listener('corr-1')
      props = double('properties', correlation_id: nil)

      expect { session.send(:handle_broker_return, return_info, props, 'p') }.not_to raise_error
      expect(event.set?).to be(false)
      expect(slot[:info]).to be_nil
    end

    it '#unregister_return_listener limpia el slot del registry' do
      session.register_return_listener('corr-1')
      session.unregister_return_listener('corr-1')

      registry = session.instance_variable_get(:@pending_returns)
      expect(registry['corr-1']).to be_nil
    end

    it 'setea el event ANTES de invocar el callback global on_return (resiliencia a user_cb que explota)' do
      BugBunny.configuration.on_return = ->(_, _, _) { raise 'boom in user callback' }

      event, slot = session.register_return_listener('corr-1')

      expect { session.send(:handle_broker_return, return_info, properties_for.call('corr-1'), 'p') }
        .not_to raise_error

      expect(event.set?).to be(true)
      expect(slot[:info]).to eq(return_info)
    end
  end

  describe '#close' do
    it 'cierra el canal y lo nilifica' do
      session.channel
      session.close

      expect(session.instance_variable_get(:@channel)).to be_nil
    end

    it 'es idempotente — no explota si se llama dos veces' do
      session.channel
      session.close
      expect { session.close }.not_to raise_error
    end

    it 'es thread-safe junto con #channel' do
      errors = []

      threads = [
        Thread.new { 10.times { session.channel rescue nil } },
        Thread.new { 10.times { session.close   rescue nil } }
      ]
      threads.each(&:join)

      expect(errors).to be_empty
    end
  end
end
