# frozen_string_literal: true

require 'spec_helper'

module ResourceAttributesSpec
  class Product < BugBunny::Resource
    attribute :name, :string
    attribute :price, :decimal
    attribute :active, :boolean
    attribute :created_at, :datetime
  end

  # Modelo remoto con un reader de conveniencia sobre el shape que devuelve el
  # servidor, y que además acepta ese mismo nombre como atributo de escritura.
  # Es el patrón que colisiona: `def name` le tapa el atributo dinámico `name`
  # al write path (gedera/bug_bunny#62).
  class Container < BugBunny::Resource
    # El servidor devuelve el nombre en `Name`, con una barra inicial. Sobre un
    # objeto recién construido ese campo no existe todavía → nil.
    def name
      @extra_attributes['Name']&.delete_prefix('/')
    end
  end

  # Misma colisión, pero el reader SÍ resuelve a un valor: lo deriva de otro
  # atributo que el constructor ya dejó puesto. Acá el método tiene que seguir
  # ganando — es el caso de los modelos cuyo builder normaliza el nombre antes
  # de mandarlo (p. ej. un sufijo `_net`).
  class Network < BugBunny::Resource
    def initialize(attributes = {})
      super
      self.Spec = { 'Name' => "#{attributes[:name] || attributes['name']}_net" }
    end

    def name
      @extra_attributes['Spec']['Name']
    end
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

  # gedera/bug_bunny#62 — `changes_to_send` leía el payload con `public_send(key)`,
  # así que un método de instancia homónimo de un atributo dinámico le tapaba el
  # valor. Cuando ese método lee un campo de la respuesta del servidor, sobre un
  # objeto nuevo devuelve nil y el atributo se enviaba como nil: la key viaja, el
  # valor se perdió, y no hay ninguna excepción. Del otro lado un `compact` lo
  # borra sin dejar rastro.
  describe 'colisión entre un atributo dinámico y un método homónimo' do
    it 'envía el valor seteado cuando el método homónimo resuelve a nil' do
      container = ResourceAttributesSpec::Container.new(
        'Image' => 'busybox:latest', 'name' => 'acs_counts_tcp_x'
      )

      expected = { 'Image' => 'busybox:latest', 'name' => 'acs_counts_tcp_x' }

      expect(container.name).to be_nil, 'el reader lee del server: sobre un objeto nuevo no hay Name'
      expect(container.changes_to_send).to eq(expected)
    end

    it 'deja ganar al método homónimo cuando resuelve a un valor' do
      network = ResourceAttributesSpec::Network.new(name: 'n1')

      expect(network.changes_to_send['name']).to eq('n1_net')
    end
  end
end
