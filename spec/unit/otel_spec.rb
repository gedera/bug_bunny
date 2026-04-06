# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BugBunny::OTel do
  describe '.messaging_headers' do
    it 'emite los campos base con messaging.system = rabbitmq' do
      headers = described_class.messaging_headers(
        operation: 'publish',
        destination: 'events_x',
        routing_key: 'users.created'
      )

      expect(headers).to include(
        :messaging_system => 'rabbitmq',
        :messaging_operation => 'publish',
        :messaging_destination_name => 'events_x',
        :messaging_routing_key => 'users.created'
      )
    end

    it 'omite messaging.message.id cuando message_id es nil' do
      headers = described_class.messaging_headers(
        operation: 'publish',
        destination: 'x',
        routing_key: 'rk'
      )

      expect(headers).not_to have_key(:messaging_message_id)
    end

    it 'incluye messaging.message.id cuando se provee' do
      headers = described_class.messaging_headers(
        operation: 'publish',
        destination: 'x',
        routing_key: 'rk',
        message_id: 'abc-123'
      )

      expect(headers[:messaging_message_id]).to eq('abc-123')
    end

    it 'coacciona destination y routing_key nil a string vacío' do
      headers = described_class.messaging_headers(
        operation: 'receive',
        destination: nil,
        routing_key: nil
      )

      expect(headers[:messaging_destination_name]).to eq('')
      expect(headers[:messaging_routing_key]).to eq('')
    end
  end
end
