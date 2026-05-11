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
