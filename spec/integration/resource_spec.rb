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
  end
end
