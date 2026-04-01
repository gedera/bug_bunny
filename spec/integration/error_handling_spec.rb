# frozen_string_literal: true

require 'spec_helper'
require 'support/integration_helper'

module ErrorSpec
  class BoomController < BugBunny::Controller
    def index
      raise StandardError, 'boom interno'
    end
  end
end

RSpec.describe 'Error handling', :integration do
  let(:queue)    { unique('error_q') }
  let(:exchange) { unique('error_x') }
  let(:client)   { BugBunny::Client.new(pool: TEST_POOL) }

  before { BugBunny.configure { |c| c.controller_namespace = 'ErrorSpec' } }
  after  { BugBunny.configure { |c| c.controller_namespace = 'BugBunny::Controllers' } }

  describe '404 — ruta no encontrada' do
    it 'retorna status 404 cuando no hay ruta para el path' do
      with_running_worker(queue: queue, exchange: exchange, routing_key: 'boom') do
        response = client.request('ruta_inexistente',
          method: :get, exchange: exchange, exchange_type: 'topic', routing_key: 'boom')

        expect(response['status']).to eq(404)
      end
    end
  end

  describe '404 — controlador no encontrado' do
    it 'retorna status 404 cuando el controlador no existe en el namespace' do
      BugBunny.configure { |c| c.controller_namespace = 'NamespaceQueNoExiste' }

      with_running_worker(queue: queue, exchange: exchange, routing_key: 'boom') do
        response = client.request('boom',
          method: :get, exchange: exchange, exchange_type: 'topic', routing_key: 'boom')

        expect(response['status']).to eq(404)
      end
    end
  end

  describe '500 — excepción en el controlador' do
    it 'retorna status 500 cuando el controlador lanza una excepción no manejada' do
      with_running_worker(queue: queue, exchange: exchange, routing_key: 'boom') do
        response = client.request('boom',
          method: :get, exchange: exchange, exchange_type: 'topic', routing_key: 'boom')

        expect(response['status']).to eq(500)
        expect(response['body']['error']).to eq('Internal Server Error')
      end
    end
  end
end
