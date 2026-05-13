# frozen_string_literal: true

require 'spec_helper'
require 'support/bunny_mocks'

RSpec.describe BugBunny::Client, 'session pooling' do
  include BunnyMocks

  # Pool falso que siempre entrega la misma conexión.
  def fake_pool(*conns)
    index = 0
    pool  = Object.new
    pool.define_singleton_method(:with) do |&block|
      block.call(conns[index % conns.size])
    ensure
      index += 1
    end
    pool
  end

  def fake_conn
    channel = BunnyMocks::FakeChannel.new(true)
    BunnyMocks::FakeConnection.new(true, channel)
  end

  # Crea un cliente con un Producer stub que responde inmediatamente.
  def client_with_pool(pool)
    client = described_class.new(pool: pool)
    # Stub Producer#rpc para que no toque RabbitMQ real
    allow_any_instance_of(BugBunny::Producer).to receive(:rpc) do |_prod, _req|
      { 'status' => 200, 'body' => '{"ok":true}' }
    end
    allow_any_instance_of(BugBunny::Producer).to receive(:fire) do |_prod, _req|
      { 'status' => 202, 'body' => nil }
    end
    client
  end

  describe 'Session reuse' do
    it 'crea una sola Session aunque se hagan múltiples requests a la misma conexión' do
      conn   = fake_conn
      client = client_with_pool(fake_pool(conn))

      session_new_count = 0
      allow(BugBunny::Session).to receive(:new).and_wrap_original do |orig, *args, **kwargs|
        session_new_count += 1
        orig.call(*args, **kwargs)
      end

      3.times { client.request('ping', method: :get, exchange: 'x', exchange_type: 'direct') }

      expect(session_new_count).to eq(1)
    end

    it 'retorna la misma instancia de Session en cada request' do
      conn   = fake_conn
      client = client_with_pool(fake_pool(conn))

      client.request('ping', method: :get, exchange: 'x', exchange_type: 'direct')
      session_after_first = conn.instance_variable_get(:@_bug_bunny_session)

      client.request('ping', method: :get, exchange: 'x', exchange_type: 'direct')
      session_after_second = conn.instance_variable_get(:@_bug_bunny_session)

      expect(session_after_first).to be(session_after_second)
    end

    it 'crea Sessions distintas para conexiones distintas' do
      conn_a = fake_conn
      conn_b = fake_conn
      pool   = fake_pool(conn_a, conn_b)
      client = client_with_pool(pool)

      client.request('ping', method: :get, exchange: 'x', exchange_type: 'direct')
      client.request('ping', method: :get, exchange: 'x', exchange_type: 'direct')

      session_a = conn_a.instance_variable_get(:@_bug_bunny_session)
      session_b = conn_b.instance_variable_get(:@_bug_bunny_session)

      expect(session_a).not_to be_nil
      expect(session_b).not_to be_nil
      expect(session_a).not_to be(session_b)
    end
  end

  describe 'Producer reuse' do
    it 'crea un solo Producer aunque se hagan múltiples requests a la misma conexión' do
      conn   = fake_conn
      client = client_with_pool(fake_pool(conn))

      producer_new_count = 0
      allow(BugBunny::Producer).to receive(:new).and_wrap_original do |orig, *args|
        producer_new_count += 1
        orig.call(*args)
      end

      3.times { client.request('ping', method: :get, exchange: 'x', exchange_type: 'direct') }

      expect(producer_new_count).to eq(1)
    end

    it 'retorna la misma instancia de Producer en cada request' do
      conn   = fake_conn
      client = client_with_pool(fake_pool(conn))

      client.request('ping', method: :get, exchange: 'x', exchange_type: 'direct')
      producer_after_first = conn.instance_variable_get(:@_bug_bunny_producer)

      client.request('ping', method: :get, exchange: 'x', exchange_type: 'direct')
      producer_after_second = conn.instance_variable_get(:@_bug_bunny_producer)

      expect(producer_after_first).to be(producer_after_second)
    end
  end

  describe 'thread-safety' do
    it 'múltiples threads con la misma conexión no generan Sessions duplicadas' do
      conn = fake_conn
      # Pool siempre devuelve la misma conexión — simula concurrencia en el mismo slot
      pool = Object.new
      mutex = Mutex.new
      pool.define_singleton_method(:with) { |&blk| mutex.synchronize { blk.call(conn) } }

      client = client_with_pool(pool)

      session_new_count = Concurrent::AtomicFixnum.new(0)
      allow(BugBunny::Session).to receive(:new).and_wrap_original do |orig, *args, **kwargs|
        session_new_count.increment
        orig.call(*args, **kwargs)
      end

      threads = 10.times.map do
        Thread.new { client.request('ping', method: :get, exchange: 'x', exchange_type: 'direct') }
      end
      threads.each(&:join)

      expect(session_new_count.value).to eq(1)
    end
  end

  describe 'Delivery mode routing' do
    def fake_conn_local
      channel = BunnyMocks::FakeChannel.new(true)
      BunnyMocks::FakeConnection.new(true, channel)
    end

    it 'publish con confirmed: true enruta a Producer#confirmed' do
      conn = fake_conn_local
      client = described_class.new(pool: fake_pool(conn))

      confirmed_called = false
      allow_any_instance_of(BugBunny::Producer).to receive(:confirmed) do |_prod, _req|
        confirmed_called = true
        { 'status' => 202, 'body' => nil }
      end

      client.publish('acct.start',
                     exchange: 'x', exchange_type: 'direct', body: { a: 1 },
                     confirmed: true)

      expect(confirmed_called).to be(true)
    end

    it 'propaga mandatory y confirm_timeout al Request' do
      conn = fake_conn_local
      client = described_class.new(pool: fake_pool(conn))

      captured = nil
      allow_any_instance_of(BugBunny::Producer).to receive(:confirmed) do |_prod, req|
        captured = req
        { 'status' => 202, 'body' => nil }
      end

      client.publish('acct.start',
                     exchange: 'x', exchange_type: 'direct',
                     confirmed: true, mandatory: true, confirm_timeout: 0.5)

      expect(captured.delivery_mode).to eq(:confirmed)
      expect(captured.mandatory).to be(true)
      expect(captured.confirm_timeout).to eq(0.5)
    end

    it 'publish sin confirmed: true sigue invocando #fire (backward compat)' do
      conn = fake_conn_local
      client = described_class.new(pool: fake_pool(conn))

      fire_called = false
      allow_any_instance_of(BugBunny::Producer).to receive(:fire) do |_prod, _req|
        fire_called = true
        { 'status' => 202, 'body' => nil }
      end

      client.publish('evt', exchange: 'x', exchange_type: 'direct', body: {})

      expect(fire_called).to be(true)
    end

    it 'send con bloque permite setear delivery_mode = :confirmed' do
      conn = fake_conn_local
      client = described_class.new(pool: fake_pool(conn))

      confirmed_called = false
      allow_any_instance_of(BugBunny::Producer).to receive(:confirmed) do |_prod, _req|
        confirmed_called = true
        { 'status' => 202, 'body' => nil }
      end

      client.send('evt.x', exchange: 'x', exchange_type: 'direct') do |req|
        req.delivery_mode = :confirmed
        req.mandatory = true
        req.confirm_timeout = 0.2
      end

      expect(confirmed_called).to be(true)
    end
  end

  describe 'warn_return_raise_misuse' do
    let(:log_io) { StringIO.new }

    before do
      @prev_logger = BugBunny.configuration.logger
      BugBunny.configuration.logger = Logger.new(log_io).tap { |l| l.level = Logger::WARN }
    end

    after do
      BugBunny.configuration.logger = @prev_logger
    end

    def stub_producer_to_noop
      allow_any_instance_of(BugBunny::Producer).to receive(:confirmed) { { 'status' => 202, 'body' => nil } }
      allow_any_instance_of(BugBunny::Producer).to receive(:fire) { { 'status' => 202, 'body' => nil } }
    end

    it 'logea warning cuando return_raise:true se pasa sin confirmed' do
      stub_producer_to_noop
      client = described_class.new(pool: fake_pool(fake_conn))

      client.publish('foo', exchange: 'x', exchange_type: 'direct',
                            return_raise: true, mandatory: true)

      expect(log_io.string).to include('event=client.return_raise_ignored')
      expect(log_io.string).to include('delivery_mode=publish')
    end

    it 'logea warning cuando return_raise:true se pasa sin mandatory' do
      stub_producer_to_noop
      client = described_class.new(pool: fake_pool(fake_conn))

      client.publish('foo', exchange: 'x', exchange_type: 'direct',
                            return_raise: true, confirmed: true)

      expect(log_io.string).to include('event=client.return_raise_ignored')
      expect(log_io.string).to include('mandatory=false')
    end

    it 'NO logea warning cuando confirmed+mandatory se setean via block API' do
      stub_producer_to_noop
      client = described_class.new(pool: fake_pool(fake_conn))

      client.publish('foo', exchange: 'x', exchange_type: 'direct', return_raise: true) do |req|
        req.delivery_mode = :confirmed
        req.mandatory = true
      end

      expect(log_io.string).not_to include('client.return_raise_ignored')
    end

    it 'NO logea warning cuando return_raise no fue seteado per-request (deja el default global)' do
      stub_producer_to_noop
      client = described_class.new(pool: fake_pool(fake_conn))

      # Default global es true, pero el caller no fue explícito → no warneamos
      client.publish('foo', exchange: 'x', exchange_type: 'direct')

      expect(log_io.string).not_to include('client.return_raise_ignored')
    end

    it 'NO logea warning cuando confirmed+mandatory+return_raise:true coexisten' do
      stub_producer_to_noop
      client = described_class.new(pool: fake_pool(fake_conn))

      client.publish('foo', exchange: 'x', exchange_type: 'direct',
                            confirmed: true, mandatory: true, return_raise: true)

      expect(log_io.string).not_to include('client.return_raise_ignored')
    end
  end

  describe 'Session no se cierra entre requests' do
    it 'no invoca close en la Session al terminar el request' do
      conn   = fake_conn
      client = client_with_pool(fake_pool(conn))

      # Primera request para crear y cachear la session
      client.request('ping', method: :get, exchange: 'x', exchange_type: 'direct')

      session = conn.instance_variable_get(:@_bug_bunny_session)
      expect(session).not_to be_nil

      # Espiamos la session cacheada y ejecutamos una segunda request
      allow(session).to receive(:close).and_call_original
      client.request('ping', method: :get, exchange: 'x', exchange_type: 'direct')

      expect(session).not_to have_received(:close)
    end
  end
end
