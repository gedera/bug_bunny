# frozen_string_literal: true

require_relative 'lib/bug_bunny'

# Clase de prueba para simular un usuario Active Record.
class TestUser < BugBunny::Resource
  self.resource_name = 'test_user'

  # Simplificado: ya no usamos el ternario redundante si ambos ramas devuelven lo mismo.
  self.exchange = 'test_exchange'

  self.exchange_type = 'topic'
  self.routing_key = 'test_user'

  attr_accessor :name, :email

  validates :name, presence: true
end
