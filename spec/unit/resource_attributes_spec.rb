# frozen_string_literal: true

require 'spec_helper'

module ResourceAttributesSpec
  class Product < BugBunny::Resource
    attribute :name, :string
    attribute :price, :decimal
    attribute :active, :boolean
    attribute :created_at, :datetime
  end
end

RSpec.describe BugBunny::Resource do
  let(:product_class) { ResourceAttributesSpec::Product }

  describe 'ActiveModel::Attributes integration' do
    it 'realiza la coerción de tipos para atributos definidos' do
      product = product_class.new(
        name: 'Teclado',
        price: '25.50',
        active: '1',
        created_at: '2026-04-01 12:00:00'
      )

      expect(product.name).to eq('Teclado')
      expect(product.price).to be_a(BigDecimal)
      expect(product.price).to eq(BigDecimal('25.50'))
      expect(product.active).to be(true)
      expect(product.created_at).to be_a(Time)
    end

    it 'permite atributos dinámicos que no están definidos' do
      product = product_class.new(name: 'Teclado', category: 'Hardware')

      expect(product.name).to eq('Teclado')
      expect(product.category).to eq('Hardware')
    end

    it 'detecta cambios tanto en atributos definidos como dinámicos usando ActiveModel::Dirty' do
      product = product_class.new(name: 'Teclado', price: 10.0)
      product.persisted = true
      product.clear_changes_information

      # Cambio en atributo definido (tipado)
      product.price = 15.0
      # Cambio en atributo dinámico
      product.sku = 'TK-123'

      expect(product.changed?).to be(true)
      expect(product.changed).to include('price', 'sku')
      
      expect(product.changes_to_send).to eq({
        'price' => 15.0,
        'sku' => 'TK-123'
      })
    end

    it 'devuelve el ID correctamente sin importar dónde esté almacenado (ID aliases)' do
      p1 = product_class.new(id: '123')
      p2 = product_class.new(ID: '456')
      p3 = product_class.new(_id: '789')
      
      expect(p1.id).to eq('123')
      expect(p2.id).to eq('456')
      expect(p3.id).to eq('789')
    end
  end
end
