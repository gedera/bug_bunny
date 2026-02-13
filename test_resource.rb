require_relative 'test_helper'

class TestUser < BugBunny::Resource
  # Configuración del Pool
  self.connection_pool = -> { nil || TEST_POOL }

  # Configuración del Exchange
  self.exchange = -> { ENV['IS_STAGING'] ? 'test_exchange' : 'test_exchange' }
  self.exchange_type = 'topic'

  # ACTUALIZADO v3.0: Usamos resource_name
  self.resource_name = 'test_users'

  # ELIMINADO: attribute :id, :integer (Causa crash en v3)
  # ELIMINADO: attribute :name, :string (Causa crash en v3)

  # Las validaciones siguen funcionando igual
  validates :name, presence: true
end
