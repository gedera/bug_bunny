require_relative 'test_helper'

class TestUser < BugBunny::Resource
  # Se decide qué pool usar en cada petición
  self.connection_pool = -> {
    nil || TEST_POOL
  }

  # El exchange cambia según el entorno
  self.exchange = -> {
    ENV['IS_STAGING'] ? 'test_exchange' : 'test_exchange'
  }

  self.exchange_type = 'topic'
  self.routing_key_prefix = 'test_user'

  attribute :id, :integer
  attribute :name, :string
  attribute :email, :string

  validates :name, presence: true
end
