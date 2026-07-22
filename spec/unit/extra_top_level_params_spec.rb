# frozen_string_literal: true

require 'spec_helper'

# Hook `extra_top_level_params`: permite a una subclase mandar params HERMANOS del
# recurso en el body del `save` (top-level, junto al `param_key`), sin que formen
# parte de los atributos del recurso ni se persistan en el modelo. Caso de uso:
# una credencial de transporte que el servidor lee como `params[:x]`.
module ExtraTopLevelParamsSpec
  # Recurso sin override: usa el hook por default (no manda extras).
  class Plain < BugBunny::Resource
    self.resource_name = 'widget'
    self.param_key     = 'widget'
    self.exchange      = 'etlp_ex'
    self.exchange_type = 'direct'
    attribute :name, :string
  end

  # Recurso que sobrescribe el hook para mandar un sibling transiente (no atributo).
  class WithSibling < BugBunny::Resource
    self.resource_name = 'service'
    self.param_key     = 'service'
    self.exchange      = 'etlp_ex'
    self.exchange_type = 'direct'
    attribute :name, :string

    attr_accessor :registry_auth

    def extra_top_level_params
      registry_auth ? { registry_auth: registry_auth } : {}
    end
  end
end

RSpec.describe 'BugBunny::Resource#extra_top_level_params' do
  let(:client) { instance_double(BugBunny::Client) }

  before do
    allow(client).to receive(:request) do |_path, **args|
      @sent_body = args[:body]
      { 'body' => {} }
    end
  end

  def save_with_stub(resource)
    allow(resource).to receive(:bug_bunny_client).and_return(client)
    resource.save
  end

  it 'default: el body solo envuelve el recurso en param_key (sin extras)' do
    save_with_stub(ExtraTopLevelParamsSpec::Plain.new(name: 'w'))

    expect(@sent_body.keys).to eq(['widget'])
  end

  it 'override: agrega el sibling top-level JUNTO al recurso envuelto, no adentro' do
    resource = ExtraTopLevelParamsSpec::WithSibling.new(name: 's').tap { |r| r.registry_auth = 'b64cred' }

    save_with_stub(resource)

    expect(@sent_body[:registry_auth]).to eq('b64cred')
    expect(@sent_body['service']).not_to have_key('registry_auth')
  end

  it 'override sin valor: no agrega el sibling (hook devuelve {})' do
    save_with_stub(ExtraTopLevelParamsSpec::WithSibling.new(name: 's'))

    expect(@sent_body.keys).to eq(['service'])
  end
end
