# frozen_string_literal: true

require 'spec_helper'
require 'support/integration_helper'

module ControllerSpec
  class PingController < BugBunny::Controller
    before_action :set_user

    def index
      render status: 200, json: { pong: true, user: @user }
    end

    def show
      render status: 200, json: { id: params[:id], user: @user }
    end

    def create
      render status: 201, json: { created: params[:name] }
    end

    private

    def set_user
      @user = 'test_user'
    end
  end

  class AroundController < BugBunny::Controller
    around_action :wrap_with_timing

    def index
      render status: 200, json: { action: 'index' }
    end

    private

    def wrap_with_timing
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
      # Solo verificamos que el around_action ejecutó el bloque
      raise 'negative elapsed' if elapsed < 0
    end
  end

  class RescueController < BugBunny::Controller
    rescue_from StandardError, with: :handle_error

    def index
      raise ArgumentError, 'something went wrong'
    end

    private

    def handle_error(e)
      render status: 422, json: { error: e.message }
    end
  end

  class NodeController < BugBunny::Controller
    def index
      nodes = params[:q] ? [{ status: params[:q][:status] }] : []
      render status: 200, json: nodes
    end

    def show
      render status: 200, json: { id: params[:id] }
    end

    def create
      render status: 201, json: { node: params[:name] }
    end

    def update
      render status: 200, json: { id: params[:id], updated: true }
    end

    def destroy
      render status: 200, json: { id: params[:id], deleted: true }
    end
  end
end

RSpec.describe BugBunny::Controller, :integration do
  let(:queue)    { unique('controller_q') }
  let(:exchange) { unique('controller_x') }
  let(:client)   { BugBunny::Client.new(pool: TEST_POOL) }

  before { BugBunny.configure { |c| c.controller_namespace = 'ControllerSpec' } }
  after  { BugBunny.configure { |c| c.controller_namespace = 'BugBunny::Controllers' } }

  describe 'before_action' do
    it 'ejecuta el callback antes de la acción y expone la variable de instancia' do
      with_running_worker(queue: queue, exchange: exchange) do
        response = client.request('ping',
          method: :get, exchange: exchange, exchange_type: 'topic', routing_key: 'ping')

        expect(response['status']).to eq(200)
        expect(response['body']['user']).to eq('test_user')
      end
    end
  end

  describe 'around_action' do
    it 'envuelve la acción y la ejecuta correctamente' do
      with_running_worker(queue: queue, exchange: exchange, routing_key: 'around') do
        response = client.request('around',
          method: :get, exchange: exchange, exchange_type: 'topic', routing_key: 'around')

        expect(response['status']).to eq(200)
        expect(response['body']['action']).to eq('index')
      end
    end
  end

  describe 'rescue_from' do
    it 'captura la excepción y retorna la respuesta del handler' do
      with_running_worker(queue: queue, exchange: exchange, routing_key: 'rescue') do
        response = client.request('rescue',
          method: :get, exchange: exchange, exchange_type: 'topic', routing_key: 'rescue')

        expect(response['status']).to eq(422)
        expect(response['body']['error']).to eq('something went wrong')
      end
    end
  end

  describe 'params desde query string' do
    it 'parsea los params del path y los expone en el controlador' do
      with_running_worker(queue: queue, exchange: exchange) do
        response = client.request('ping/42',
          method: :get, exchange: exchange, exchange_type: 'topic')

        expect(response['status']).to eq(200)
        expect(response['body']['id']).to eq('42')
      end
    end
  end
end
