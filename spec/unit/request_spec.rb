# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BugBunny::Request do
  subject(:request) do
    req = described_class.new('users/42')
    req.exchange = 'users_x'
    req.method = :post
    req
  end

  describe '#amqp_options' do
    it 'inyecta los campos OTel con operation=publish como string keys' do
      headers = request.amqp_options[:headers]

      expect(headers).to include(
        'messaging_system' => 'rabbitmq',
        'messaging_operation' => 'publish',
        'messaging_destination_name' => 'users_x',
        'messaging_routing_key' => 'users/42'
      )
    end

    it 'incluye messaging_message_id cuando hay correlation_id' do
      request.correlation_id = 'corr-xyz'

      expect(request.amqp_options[:headers]['messaging_message_id']).to eq('corr-xyz')
    end

    it 'omite messaging_message_id cuando no hay correlation_id' do
      expect(request.amqp_options[:headers]).not_to have_key('messaging_message_id')
    end

    it 'preserva x-http-method con el verbo en mayúsculas' do
      expect(request.amqp_options[:headers]['x-http-method']).to eq('POST')
    end

    it 'permite a headers del usuario sobrescribir campos OTel' do
      request.headers = { 'messaging_system' => 'custom-broker' }

      expect(request.amqp_options[:headers]['messaging_system']).to eq('custom-broker')
    end

    it 'no permite al usuario pisar x-http-method' do
      request.headers = { 'x-http-method' => 'HACK' }

      expect(request.amqp_options[:headers]['x-http-method']).to eq('POST')
    end
  end
end
