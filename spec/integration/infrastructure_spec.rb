# frozen_string_literal: true

require 'spec_helper'
require 'support/integration_helper'

# Controladores de prueba aislados en namespace propio
module InfraSpec
  class PingController < BugBunny::Controller
    def index
      render status: 200, json: { message: 'pong', namespace: 'InfraSpec' }
    end

    def show
      render status: 200, json: { id: params[:id], message: 'pong', namespace: 'InfraSpec' }
    end
  end
end

class InfraSpecResource < BugBunny::Resource
  self.resource_name  = 'ping'
  self.exchange       = 'infra_spec_exchange'
  self.exchange_type  = 'topic'
end

RSpec.describe 'Infrastructure', :integration do
  let(:queue)    { unique('infra_q') }
  let(:exchange) { 'infra_spec_exchange' }

  before do
    BugBunny.configure { |c| c.controller_namespace = 'InfraSpec' }
  end

  after do
    BugBunny.configure { |c| c.controller_namespace = 'BugBunny::Controllers' }
  end

  it 'levanta el worker y cede el control al bloque' do
    with_running_worker(queue: queue, exchange: exchange) do
      expect(true).to be(true)
    end
  end

  it 'resuelve el namespace del controlador dinámicamente' do
    with_running_worker(queue: queue, exchange: exchange) do
      resource = InfraSpecResource.find('42')

      expect(resource.id).to eq('42')
      expect(resource.namespace).to eq('InfraSpec')
      expect(resource.message).to eq('pong')
    end
  end
end
