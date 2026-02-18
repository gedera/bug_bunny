# frozen_string_literal: true

require_relative '../test_helper'

# --- CLASES DE PRUEBA (Namespace Aislado) ---
module InfraTest
  class PingController < BugBunny::Controller
    # Agregamos SHOW para soportar el .find del test
    def show
      render status: 200, json: { id: params[:id], message: 'pong', namespace: 'InfraTest' }
    end

    def index
      render status: 200, json: { message: 'pong_index', namespace: 'InfraTest' }
    end
  end
end

class InfraResource < BugBunny::Resource
  self.resource_name = 'ping'
  self.exchange = 'test_infra_exchange'
  self.exchange_type = 'topic'
end

# --- SUITE DE INFRAESTRUCTURA ---
class InfrastructureTest < Minitest::Test
  include IntegrationHelper

  def setup
    skip "RabbitMQ no disponible" unless IntegrationHelper.rabbitmq_available?
    @queue = "test_infra_queue_#{SecureRandom.hex(4)}"
    @exchange = "test_infra_exchange"
  end

  def test_00_worker_lifecycle
    with_running_worker(queue: @queue, exchange: @exchange) do
      assert true, "El worker levantó y cedió el control al bloque"
    end
  end

  def test_01_dynamic_namespace_resolution
    BugBunny.configure do |c|
      c.controller_namespace = 'InfraTest'
    end

    with_running_worker(queue: @queue, exchange: @exchange) do
      # Enviamos GET ping/123 -> InfraTest::PingController#show
      resource = InfraResource.find('123')

      # Verificamos que volvió el objeto construido
      assert_equal '123', resource.id
      assert_equal 'InfraTest', resource.namespace
      assert_equal 'pong', resource.message
    end

  ensure
    BugBunny.configure do |c|
      c.controller_namespace = 'Rabbit::Controllers'
    end
  end
end
