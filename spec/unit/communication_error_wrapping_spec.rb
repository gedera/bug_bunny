# frozen_string_literal: true

require 'spec_helper'
require 'support/bunny_mocks'

# Specs para el contrato de envoltura definido en issue #49:
# cualquier `Bunny::Exception` que escape de las fronteras de abstracción del
# gem (`BugBunny.create_connection`, `BugBunny::Client#publish`/`#request`/`#send`,
# `BugBunny::Producer#confirmed`) debe re-raisearse como
# `BugBunny::CommunicationError`, preservando la excepción original en `.cause`.
RSpec.describe 'Bunny::Exception → BugBunny::CommunicationError wrapping' do
  include BunnyMocks

  describe 'BugBunny.create_connection' do
    before { BugBunny.configuration ||= BugBunny::Configuration.new }

    it 'envuelve Bunny::TCPConnectionFailedForAllHosts en CommunicationError' do
      fake_session = instance_double(Bunny::Session)
      allow(fake_session).to receive(:after_recovery_completed)
      allow(fake_session).to receive(:start).and_raise(Bunny::TCPConnectionFailedForAllHosts)
      allow(Bunny).to receive(:new).and_return(fake_session)

      err = capture_error { BugBunny.create_connection(host: 'broker.invalid', port: 5672) }
      expect(err).to be_a(BugBunny::CommunicationError)
      expect(err.message).to match(/broker.invalid:5672/)
      expect(err.cause).to be_a(Bunny::TCPConnectionFailed)
    end

    it 'envuelve cualquier Bunny::Exception, no solo TCP' do
      fake_session = instance_double(Bunny::Session)
      allow(fake_session).to receive(:after_recovery_completed)
      allow(fake_session).to receive(:start).and_raise(Bunny::AuthenticationFailureError.new('guest', '/', 0))
      allow(Bunny).to receive(:new).and_return(fake_session)

      err = capture_error { BugBunny.create_connection }
      expect(err).to be_a(BugBunny::CommunicationError)
      expect(err.cause).to be_a(Bunny::AuthenticationFailureError)
    end
  end

  describe 'Client#publish — TCP fail en try_create (issue #49 caso original)' do
    it 'envuelve Bunny::TCPConnectionFailedForAllHosts levantado dentro de @pool.with' do
      # Pool falso que levanta la excepción raw de bunny al adquirir slot —
      # simula exactamente lo observado en producción en el stack trace del issue.
      raising_pool = Object.new
      raising_pool.define_singleton_method(:with) { |&_block| raise Bunny::TCPConnectionFailedForAllHosts }

      client = BugBunny::Client.new(pool: raising_pool)

      err = capture_error { client.publish('evt', exchange: 'x', exchange_type: 'direct', body: { a: 1 }) }
      expect(err).to be_a(BugBunny::CommunicationError)
      expect(err.message).to match(/AMQP failure on path=evt/)
      expect(err.cause).to be_a(Bunny::TCPConnectionFailed)
    end
  end

  describe 'Client — in-flight ConnectionClosedError' do
    it 'envuelve Bunny::ConnectionClosedError levantado por el Producer' do
      conn    = BunnyMocks::FakeConnection.new(true, BunnyMocks::FakeChannel.new(true))
      pool    = Object.new.tap { |p| p.define_singleton_method(:with) { |&blk| blk.call(conn) } }
      client  = BugBunny::Client.new(pool: pool)

      allow_any_instance_of(BugBunny::Producer).to receive(:fire)
        .and_raise(Bunny::ConnectionClosedError.new('connection lost'))

      err = capture_error { client.publish('evt', exchange: 'x', exchange_type: 'direct', body: { a: 1 }) }
      expect(err).to be_a(BugBunny::CommunicationError)
      expect(err.message).to match(/AMQP failure/)
      expect(err.cause).to be_a(Bunny::ConnectionClosedError)
    end
  end

  describe 'Client — pass-through de BugBunny::Error' do
    it 'no re-envuelve errores propios del gem (RequestTimeout, PublishNacked, etc.)' do
      conn    = BunnyMocks::FakeConnection.new(true, BunnyMocks::FakeChannel.new(true))
      pool    = Object.new.tap { |p| p.define_singleton_method(:with) { |&blk| blk.call(conn) } }
      client  = BugBunny::Client.new(pool: pool)

      allow_any_instance_of(BugBunny::Producer).to receive(:rpc)
        .and_raise(BugBunny::RequestTimeout.new('timeout'))

      expect { client.request('foo', method: :get, exchange: 'x', exchange_type: 'direct') }
        .to raise_error(BugBunny::RequestTimeout)
    end
  end

  describe 'Producer#confirmed — rescue limitado a Bunny::Exception' do
    it 'no traga errores genéricos de Ruby (NoMethodError) como CommunicationError' do
      producer = BugBunny::Producer.new(instance_double(BugBunny::Session))
      allow(producer).to receive(:setup_return_listener).and_return(nil)
      allow(producer).to receive(:teardown_return_listener)
      allow(producer).to receive(:publish_message).and_raise(NoMethodError.new('bug interno'))

      request = BugBunny::Request.new('evt').tap do |r|
        r.exchange = 'x'
        r.exchange_type = 'direct'
        r.delivery_mode = :confirmed
      end

      expect { producer.confirmed(request) }.to raise_error(NoMethodError, 'bug interno')
    end

    it 'envuelve Bunny::Exception como CommunicationError' do
      producer = BugBunny::Producer.new(instance_double(BugBunny::Session))
      allow(producer).to receive(:setup_return_listener).and_return(nil)
      allow(producer).to receive(:teardown_return_listener)
      allow(producer).to receive(:publish_message)
        .and_raise(Bunny::ChannelAlreadyClosed.new('closed', double(id: 1)))

      request = BugBunny::Request.new('evt').tap do |r|
        r.exchange = 'x'
        r.exchange_type = 'direct'
        r.delivery_mode = :confirmed
      end

      err = capture_error { producer.confirmed(request) }
      expect(err).to be_a(BugBunny::CommunicationError)
      expect(err.message).to match(/Publisher confirms failed/)
      expect(err.cause).to be_a(Bunny::ChannelAlreadyClosed)
    end
  end

  def capture_error
    yield
    nil
  rescue StandardError => e
    e
  end
end
