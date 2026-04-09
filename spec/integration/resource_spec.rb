# frozen_string_literal: true

require 'spec_helper'
require 'support/integration_helper'

module ResourceSpec
  class NodeController < BugBunny::Controller
    def index
      nodes = params[:q] ? [{ id: '1', status: params.dig(:q, :status) }] : [{ id: '1' }, { id: '2' }]
      render status: 200, json: nodes
    end

    def show
      render status: 200, json: { id: params[:id], name: 'node-01' }
    end

    def create
      render status: 201, json: { id: '99', name: params.dig(:node, :name) }
    end

    def update
      render status: 200, json: { id: params[:id], updated: true, name: params.dig(:node, 'name') }
    end

    def destroy
      render status: 200, json: { id: params[:id], deleted: true }
    end
  end
end

class SpecNode < BugBunny::Resource
  self.resource_name = 'node'
  self.param_key     = 'node'
  self.exchange      = 'resource_spec_exchange'
  self.exchange_type = 'topic'
end

RSpec.describe BugBunny::Resource, :integration do
  let(:queue)    { unique('resource_q') }
  let(:exchange) { 'resource_spec_exchange' }

  before { BugBunny.configure { |c| c.controller_namespace = 'ResourceSpec' } }
  after  { BugBunny.configure { |c| c.controller_namespace = 'BugBunny::Controllers' } }

  describe '.find' do
    it 'retorna el recurso por id' do
      with_running_worker(queue: queue, exchange: exchange) do
        node = SpecNode.find('1')

        expect(node.id).to eq('1')
        expect(node.name).to eq('node-01')
      end
    end
  end

  describe '.where' do
    it 'retorna todos los recursos sin filtros' do
      with_running_worker(queue: queue, exchange: exchange) do
        nodes = SpecNode.where

        expect(nodes).to be_an(Array)
        expect(nodes.length).to eq(2)
      end
    end

    it 'pasa los filtros como query params al controlador' do
      with_running_worker(queue: queue, exchange: exchange) do
        nodes = SpecNode.where(q: { status: 'active' })

        expect(nodes).to be_an(Array)
        expect(nodes.first.status).to eq('active')
      end
    end
  end

  describe '.create' do
    it 'crea el recurso y retorna el objeto creado' do
      with_running_worker(queue: queue, exchange: exchange) do
        node = SpecNode.create(name: 'node-nuevo')

        expect(node.id).to eq('99')
        expect(node.name).to eq('node-nuevo')
      end
    end
  end

  describe '#update' do
    it 'actualiza el recurso por id' do
      with_running_worker(queue: queue, exchange: exchange) do
        node = SpecNode.new(id: '1')
        node.persisted = true
        result = node.update(name: 'node-actualizado')

        expect(result).to be(true)
        expect(node.id).to eq('1')
        expect(node.updated).to be(true)
      end
    end
  end

  describe '#destroy' do
    it 'elimina el recurso por id' do
      with_running_worker(queue: queue, exchange: exchange) do
        node = SpecNode.new(id: '1')
        node.persisted = true
        result = node.destroy

        expect(result).to be(true)
        expect(node.persisted?).to be(false)
      end
    end

    it 'carga errores de validación cuando el servidor responde 422' do
      node = SpecNode.new(id: '1')
      node.persisted = true

      error = BugBunny::UnprocessableEntity.new({ 'errors' => { 'base' => ['resource is in use'] } })
      allow(node).to receive(:bug_bunny_client).and_raise(error)

      expect(node.destroy).to be(false)
      expect(node.errors[:base]).to include('resource is in use')
    end

    it 'carga el mensaje de error cuando el servidor responde 4xx' do
      node = SpecNode.new(id: '1')
      node.persisted = true

      allow(node).to receive(:bug_bunny_client).and_raise(BugBunny::BadRequest, 'secret is in use by: radius_1')

      expect(node.destroy).to be(false)
      expect(node.errors[:base]).to include('secret is in use by: radius_1')
    end

    it 'retorna false sin errores cuando el servidor responde 5xx' do
      node = SpecNode.new(id: '1')
      node.persisted = true

      allow(node).to receive(:bug_bunny_client).and_raise(BugBunny::InternalServerError, 'boom')

      expect(node.destroy).to be(false)
      expect(node.errors).to be_empty
    end
  end

  describe '#inspect' do
    let(:node) { SpecNode.new(id: '123', name: 'test-node', status: 'active', ip: '192.168.1.1', port: 8080) }

    it 'muestra id y persisted' do
      expect(node.inspect).to include('id="123"')
      expect(node.inspect).to include('persisted=false')
    end

    it 'muestra atributos principales sin detalles de infraestructura' do
      result = node.inspect

      expect(result).to include('name="test-node"')
      expect(result).to include('status="active"')
      expect(result).to include('ip="192.168.1.1"')
      expect(result).to include('port=8080')
      expect(result).not_to include('routing_key')
      expect(result).not_to include('exchange')
    end

    it 'filtra atributos de infraestructura cuando están presentes' do
      node.routing_key = 'radius_1'
      node.exchange = 'test_exchange'
      node.exchange_type = 'topic'
      node.exchange_options = { durable: true }
      node.persisted = true

      result = node.inspect

      expect(result).not_to include('routing_key')
      expect(result).not_to include('exchange')
      expect(result).not_to include('exchange_type')
      expect(result).not_to include('exchange_options')
      expect(result).to include('persisted=true')
    end

    it 'limita a 5 atributos principales' do
      node = SpecNode.new(id: '1', a: '1', b: '2', c: '3', d: '4', e: '5', f: '6')

      result = node.inspect

      expect(result.scan('=').length).to be <= 7 # id + persisted + max 5 attrs
    end
  end
end
