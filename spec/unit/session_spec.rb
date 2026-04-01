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
