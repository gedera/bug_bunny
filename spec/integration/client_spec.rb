# frozen_string_literal: true

require 'spec_helper'
require 'support/integration_helper'

module ClientSpec
  class EchoController < BugBunny::Controller
    def index
      render status: 200, json: { received: params[:message], via: 'ClientSpec::EchoController' }
    end
  end
end

RSpec.describe BugBunny::Client, :integration do
  let(:queue)    { unique('client_q') }
  let(:exchange) { unique('client_x') }
  let(:client)   { described_class.new(pool: TEST_POOL) }

  before { BugBunny.configure { |c| c.controller_namespace = 'ClientSpec' } }
  after  { BugBunny.configure { |c| c.controller_namespace = 'BugBunny::Controllers' } }

  describe '#publish' do
    context 'con exchange topic' do
      it 'entrega el mensaje con el routing key correcto' do
        with_spy_worker(queue: queue, exchange: exchange, exchange_type: 'topic', routing_key: 'logs.#') do |messages|
          client.publish('logs.error', exchange: exchange, exchange_type: 'topic', body: { level: 'error' })

          msg = wait_for_message(messages)
          expect(msg[:routing_key]).to eq('logs.error')
        end
      end
    end

    context 'con exchange direct' do
      it 'entrega el mensaje al routing key exacto' do
        with_spy_worker(queue: queue, exchange: exchange, exchange_type: 'direct', routing_key: 'alerts') do |messages|
          client.publish('alerts', exchange: exchange, exchange_type: 'direct', body: { alert: true })

          msg = wait_for_message(messages)
          expect(msg[:routing_key]).to eq('alerts')
        end
      end
    end

    context 'con exchange fanout' do
      it 'entrega el mensaje ignorando el routing key' do
        with_spy_worker(queue: queue, exchange: exchange, exchange_type: 'fanout', routing_key: '') do |messages|
          client.publish('cualquier.key', exchange: exchange, exchange_type: 'fanout', body: { data: 1 })

          msg = wait_for_message(messages)
          expect(msg[:routing_key]).to eq('cualquier.key')
        end
      end
    end
  end

  describe '#request (RPC)' do
    context 'con exchange topic' do
      it 'retorna la respuesta del controlador' do
        with_running_worker(queue: queue, exchange: exchange, exchange_type: 'topic', routing_key: 'echo') do
          response = client.request('echo',
            method: :get, exchange: exchange, exchange_type: 'topic',
            body: { message: 'hello_topic' })

          expect(response['status']).to eq(200)
          expect(response['body']['received']).to eq('hello_topic')
        end
      end
    end

    context 'con exchange direct' do
      it 'retorna la respuesta del controlador' do
        with_running_worker(queue: queue, exchange: exchange, exchange_type: 'direct', routing_key: 'echo') do
          response = client.request('echo',
            method: :get, routing_key: 'echo',
            exchange: exchange, exchange_type: 'direct',
            body: { message: 'hello_direct' })

          expect(response['status']).to eq(200)
          expect(response['body']['received']).to eq('hello_direct')
        end
      end
    end

    context 'con exchange fanout' do
      it 'retorna la respuesta del controlador' do
        with_running_worker(queue: queue, exchange: exchange, exchange_type: 'fanout', routing_key: '') do
          response = client.request('echo',
            method: :get, exchange: exchange, exchange_type: 'fanout',
            body: { message: 'hello_fanout' })

          expect(response['status']).to eq(200)
          expect(response['body']['received']).to eq('hello_fanout')
        end
      end
    end

    context 'con exchange_options personalizadas (cascada nivel 3)' do
      it 'publica sin error PRECONDITION_FAILED' do
        custom_x = unique('custom_x')
        conn = BugBunny.create_connection
        ch   = conn.create_channel
        ch.direct(custom_x, durable: true, auto_delete: true)

        expect do
          client.publish('key',
            exchange: custom_x, exchange_type: 'direct',
            exchange_options: { durable: true, auto_delete: true },
            body: { test: true })
        end.not_to raise_error
      ensure
        ch&.exchange_delete(custom_x) rescue nil
        conn&.close rescue nil
      end
    end
  end
end
