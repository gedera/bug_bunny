# frozen_string_literal: true

require_relative '../test_helper'

class HybridResourceTest < Minitest::Test
  # Definimos una clase temporal para el test
  class Product < BugBunny::Resource
    # Atributos explícitos (Tipados)
    attribute :price, :decimal, default: 0.0
    attribute :active, :boolean, default: false

    # Validaciones mixtas
    validates :price, numericality: { greater_than: 0 }
    validates :name, presence: true # 'name' será dinámico
  end

  def test_hybrid_attributes_assignment
    # Caso: Asignación mixta en initialize
    p = Product.new(price: "10.5", name: "Laptop", active: "1")

    # 1. Atributo Tipado (:decimal) -> Coerción automática
    assert_kind_of BigDecimal, p.price
    assert_equal 10.5, p.price

    # 2. Atributo Tipado (:boolean) -> Coerción automática
    assert_equal true, p.active

    # 3. Atributo Dinámico (method_missing) -> String directo
    assert_equal "Laptop", p.name
  end

  def test_hybrid_serialization
    p = Product.new(price: 20.0, name: "Mouse")

    # Simulamos serialización (lo que se enviaría a RabbitMQ)
    payload = p.attributes_for_serialization

    assert_equal 20.0, payload['price']
    assert_equal "Mouse", payload['name']
    assert_equal false, payload['active'] # Default value
  end

  def test_hybrid_dirty_tracking
    p = Product.new(price: 10.0, name: "Old Name")
    p.persisted = true
    p.send(:clear_changes_information)

    # Modificamos uno tipado y uno dinámico
    p.price = 15.0
    p.name = "New Name"

    changes = p.changes_to_send

    # Ambos deben aparecer en los cambios
    assert_includes changes.keys, 'price'
    assert_includes changes.keys, 'name'
    assert_equal 15.0, changes['price']
    assert_equal "New Name", changes['name']
  end
end
