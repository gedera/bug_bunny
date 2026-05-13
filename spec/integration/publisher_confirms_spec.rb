# frozen_string_literal: true

require 'spec_helper'
require 'support/integration_helper'

# Specs de integración para Publisher Confirms en modo :confirmed + mandatory.
# Verifican el flow end-to-end del bridge `basic.return` → `PublishUnroutable`
# contra un RabbitMQ real.
#
# Se skippean automáticamente si el broker no está disponible (ver
# `spec_helper.rb` → `before(:each, :integration)`).
RSpec.describe 'Publisher Confirms — return_raise', :integration do
  let(:client) { BugBunny::Client.new(pool: TEST_POOL) }

  # Exchange unbound: existe pero ninguna cola está bindeada a él.
  # Cualquier publish con mandatory:true sobre este exchange retornará.
  let(:unbound_exchange) { unique('unroutable_x') }
  # Exchange con cola bindeada: publish con mandatory:true llega bien.
  let(:routable_exchange) { unique('routable_x') }
  let(:routable_queue)    { unique('routable_q') }

  # Declara el exchange sin bindings para asegurar que `basic.return` se dispare.
  # Usa una conexión fresca para no contaminar el pool.
  def declare_unbound_exchange!(name)
    conn = BugBunny.create_connection
    ch = conn.create_channel
    ch.topic(name, BugBunny.configuration.exchange_options)
    ch.close
    conn.close
  end

  before do
    declare_unbound_exchange!(unbound_exchange)
    # Reset flag a default conocido por si algún spec previo lo cambió.
    BugBunny.configuration.return_raise = true
    BugBunny.configuration.on_return = nil
  end

  after do
    BugBunny.configuration.return_raise = true
    BugBunny.configuration.on_return = nil
  end

  describe 'mandatory: true sobre exchange sin bindings' do
    it 'levanta BugBunny::PublishUnroutable por default (return_raise=true)' do
      expect {
        client.publish('acct.unbound',
                       exchange: unbound_exchange,
                       exchange_type: 'topic',
                       confirmed: true,
                       mandatory: true,
                       body: { tenant: 42 })
      }.to raise_error(BugBunny::PublishUnroutable) do |err|
        expect(err.path).to eq('acct.unbound')
        expect(err.exchange).to eq(unbound_exchange)
        expect(err.routing_key).to eq('acct.unbound')
        expect(err.reply_code).to eq(312)
        expect(err.reply_text).to match(/NO_ROUTE/i)
        expect(err.correlation_id).to be_a(String)
        expect(err.correlation_id).not_to be_empty
      end
    end

    it 'NO levanta si el request override `return_raise: false`' do
      result = client.publish('acct.unbound',
                              exchange: unbound_exchange,
                              exchange_type: 'topic',
                              confirmed: true,
                              mandatory: true,
                              return_raise: false,
                              body: { tenant: 42 })

      expect(result).to eq('status' => 202, 'body' => nil)
    end

    it 'NO levanta si la config global tiene `return_raise = false`' do
      BugBunny.configuration.return_raise = false

      result = client.publish('acct.unbound',
                              exchange: unbound_exchange,
                              exchange_type: 'topic',
                              confirmed: true,
                              mandatory: true,
                              body: { tenant: 42 })

      expect(result).to eq('status' => 202, 'body' => nil)
    end

    it 'invoca el callback global on_return antes de levantar' do
      captured = nil
      BugBunny.configuration.on_return = lambda { |return_info, _props, _body|
        captured = { exchange: return_info.exchange, rk: return_info.routing_key }
      }

      expect {
        client.publish('acct.unbound',
                       exchange: unbound_exchange,
                       exchange_type: 'topic',
                       confirmed: true,
                       mandatory: true,
                       body: { tenant: 42 })
      }.to raise_error(BugBunny::PublishUnroutable)

      expect(captured).not_to be_nil
      expect(captured[:exchange]).to eq(unbound_exchange)
      expect(captured[:rk]).to eq('acct.unbound')
    end

    it 'levanta igual cuando el user_cb on_return explota' do
      BugBunny.configuration.on_return = ->(_, _, _) { raise 'boom in user cb' }

      expect {
        client.publish('acct.unbound',
                       exchange: unbound_exchange,
                       exchange_type: 'topic',
                       confirmed: true,
                       mandatory: true,
                       body: { tenant: 42 })
      }.to raise_error(BugBunny::PublishUnroutable)
    end

    it 'override per-request gana sobre config global = false' do
      BugBunny.configuration.return_raise = false

      expect {
        client.publish('acct.unbound',
                       exchange: unbound_exchange,
                       exchange_type: 'topic',
                       confirmed: true,
                       mandatory: true,
                       return_raise: true,
                       body: { tenant: 42 })
      }.to raise_error(BugBunny::PublishUnroutable)
    end
  end

  describe 'mandatory: true sobre exchange con binding (happy path)' do
    # Declara queue exclusive + binding contra `routable_exchange` para que el
    # publish sea ruteable. Exclusive evita la deprecación de transient_nonexcl_queues
    # en versiones modernas de RabbitMQ.
    def with_exclusive_binding(exchange:, routing_key:)
      conn = BugBunny.create_connection
      ch = conn.create_channel
      x = ch.topic(exchange, BugBunny.configuration.exchange_options)
      q = ch.queue('', exclusive: true, auto_delete: true)
      q.bind(x, routing_key: routing_key)
      yield
    ensure
      ch&.close
      conn&.close
    end

    it 'retorna 202 sin levantar — el mensaje rutea normal' do
      with_exclusive_binding(exchange: routable_exchange, routing_key: 'acct.#') do
        result = client.publish('acct.start',
                                exchange: routable_exchange,
                                exchange_type: 'topic',
                                confirmed: true,
                                mandatory: true,
                                body: { tenant: 99 })

        expect(result).to eq('status' => 202, 'body' => nil)
      end
    end
  end

  describe 'mandatory: false (flag inerte)' do
    it 'no levanta aunque return_raise=true y la routing key no rutee a ninguna cola' do
      result = client.publish('acct.unbound',
                              exchange: unbound_exchange,
                              exchange_type: 'topic',
                              confirmed: true,
                              mandatory: false,
                              return_raise: true,
                              body: { tenant: 1 })

      expect(result).to eq('status' => 202, 'body' => nil)
    end
  end
end
