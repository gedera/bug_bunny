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

  describe 'concurrencia multi-thread sobre el mismo client' do
    # Verifica que la correlación por correlation_id aísla los outcomes:
    # N threads publican simultáneamente sobre el mismo exchange unbound, cada uno
    # debe recibir SU propio PublishUnroutable (no el de otro thread).
    it 'cada caller recibe su propio raise sin contaminación cross-thread' do
      threads = 8
      results = Concurrent::Array.new

      pool = Array.new(threads) do |i|
        Thread.new do
          rk = "thread.#{i}.unbound"
          client.publish(rk,
                         exchange: unbound_exchange,
                         exchange_type: 'topic',
                         confirmed: true,
                         mandatory: true,
                         body: { tid: i })
          results << { tid: i, raised: false }
        rescue BugBunny::PublishUnroutable => e
          results << { tid: i, raised: true, rk: e.routing_key, cid: e.correlation_id }
        end
      end

      pool.each(&:join)

      expect(results.size).to eq(threads)
      expect(results.all? { |r| r[:raised] }).to be(true), 'todos deberían haber raised'
      expect(results.map { |r| r[:rk] }.sort).to eq((0...threads).map { |i| "thread.#{i}.unbound" }.sort)
      # Todos los correlation_ids deben ser distintos (no hubo cross-thread leakage)
      cids = results.map { |r| r[:cid] }
      expect(cids.uniq.size).to eq(threads)
    end
  end

  describe 'aislamiento entre exchanges sobre el mismo channel' do
    # Publish A sobre exchange unbound (debe raisear) y publish B sobre exchange routable
    # (debe pasar). Validamos que el return de A no contamina B.
    it 'return en exchange A no afecta publish concurrente a exchange B' do
      bound_ex = unique('bound_b_x')
      bound_q = unique('bound_b_q')

      # Setup: exchange routable con queue exclusive bindeada
      conn = BugBunny.create_connection
      ch = conn.create_channel
      x = ch.topic(bound_ex, BugBunny.configuration.exchange_options)
      q = ch.queue('', exclusive: true, auto_delete: true)
      q.bind(x, routing_key: '#')

      results = Concurrent::Array.new

      t_a = Thread.new do
        client.publish('a.unbound',
                       exchange: unbound_exchange,
                       exchange_type: 'topic',
                       confirmed: true,
                       mandatory: true,
                       body: { side: 'A' })
        results << { side: 'A', raised: false }
      rescue BugBunny::PublishUnroutable
        results << { side: 'A', raised: true }
      end

      t_b = Thread.new do
        client.publish('b.routable',
                       exchange: bound_ex,
                       exchange_type: 'topic',
                       confirmed: true,
                       mandatory: true,
                       body: { side: 'B' })
        results << { side: 'B', raised: false }
      rescue BugBunny::PublishUnroutable
        results << { side: 'B', raised: true }
      end

      [t_a, t_b].each(&:join)

      a = results.find { |r| r[:side] == 'A' }
      b = results.find { |r| r[:side] == 'B' }
      expect(a[:raised]).to be(true),  'A (unbound) debería haber raised'
      expect(b[:raised]).to be(false), 'B (routable) NO debería haber raised'
    ensure
      ch&.close
      conn&.close
    end
  end

  describe 'no hay leak en el registry tras publishes seriales' do
    # 30 publishes seriales (mix routable + unroutable). Tras todos, el registry
    # @pending_returns debe estar en 0. Detecta entries colgadas por cleanup mal hecho.
    it 'registry vuelve a 0 tras una serie de publishes' do
      30.times do |i|
        target = i.even? ? unbound_exchange : nil
        if target
          begin
            client.publish("serial.#{i}",
                           exchange: target,
                           exchange_type: 'topic',
                           confirmed: true,
                           mandatory: true,
                           body: { i: i })
          rescue BugBunny::PublishUnroutable
            # esperado en routes no-ruteables
          end
        else
          # publish sin mandatory para no triggerear return — no-op para el registry
          client.publish("serial.#{i}",
                         exchange: unbound_exchange,
                         exchange_type: 'topic',
                         confirmed: true,
                         mandatory: false,
                         body: { i: i })
        end
      end

      # Inspeccionar cada Session del pool — el registry debe estar vacío en todas.
      total_pending = 0
      TEST_POOL.with do |conn|
        session = conn.instance_variable_get(:@_bug_bunny_session)
        registry = session.instance_variable_get(:@pending_returns)
        total_pending += registry.size
      end
      expect(total_pending).to eq(0)
    end
  end
end
