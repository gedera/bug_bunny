# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BugBunny::Routing::Route do
  describe '#match? and #extract_params — path normalization' do
    let(:route) { described_class.new('GET', 'services/otaigccd59q0k7kxb1h193go2/restart', to: 'services#restart') }

    it 'matches path without leading slash' do
      expect(route.match?('GET', 'services/otaigccd59q0k7kxb1h193go2/restart')).to be true
    end

    it 'matches path with leading slash' do
      expect(route.match?('GET', '/services/otaigccd59q0k7kxb1h193go2/restart')).to be true
    end

    it 'matches path with trailing slash' do
      expect(route.match?('GET', 'services/otaigccd59q0k7kxb1h193go2/restart/')).to be true
    end

    it 'matches path with leading and trailing slash' do
      expect(route.match?('GET', '/services/otaigccd59q0k7kxb1h193go2/restart/')).to be true
    end

    it 'extracts params from path without slash' do
      params = route.extract_params('services/otaigccd59q0k7kxb1h193go2/restart')
      expect(params).to eq({})
    end

    it 'extracts params from path with slash' do
      params = route.extract_params('/services/otaigccd59q0k7kxb1h193go2/restart')
      expect(params).to eq({})
    end

    context 'route with dynamic segment' do
      let(:route_with_id) { described_class.new('GET', 'nodes/:id', to: 'nodes#show') }

      it 'extracts params from path without slash' do
        params = route_with_id.extract_params('nodes/123')
        expect(params).to eq({ 'id' => '123' })
      end

      it 'extracts params from path with slash' do
        params = route_with_id.extract_params('/nodes/123')
        expect(params).to eq({ 'id' => '123' })
      end
    end

    context 'route defined with leading slash' do
      let(:route_with_leading_slash) do
        described_class.new('GET', '/services/otaigccd59q0k7kxb1h193go2/restart', to: 'services#restart')
      end

      it 'matches path without slash' do
        expect(route_with_leading_slash.match?('GET', 'services/otaigccd59q0k7kxb1h193go2/restart')).to be true
      end

      it 'matches path with slash' do
        expect(route_with_leading_slash.match?('GET', '/services/otaigccd59q0k7kxb1h193go2/restart')).to be true
      end
    end
  end

  describe 'RouteSet#recognize path normalization' do
    let(:route_set) { BugBunny::Routing::RouteSet.new }

    before do
      route_set.draw do
        get 'services/otaigccd59q0k7kxb1h193go2/restart', to: 'services#restart'
      end
    end

    it 'recognizes path without slash' do
      result = route_set.recognize('GET', 'services/otaigccd59q0k7kxb1h193go2/restart')
      expect(result).not_to be_nil
      expect(result[:controller]).to eq('services')
      expect(result[:action]).to eq('restart')
    end

    it 'recognizes path with leading slash' do
      result = route_set.recognize('GET', '/services/otaigccd59q0k7kxb1h193go2/restart')
      expect(result).not_to be_nil
      expect(result[:controller]).to eq('services')
      expect(result[:action]).to eq('restart')
    end

    it 'returns nil for non-matching path' do
      result = route_set.recognize('GET', 'services/nonexistent')
      expect(result).to be_nil
    end
  end

  describe 'Consumer path handling — URI parsing edge case' do
    let(:channel) { BunnyMocks::FakeChannel.new(true) }
    let(:connection) { BunnyMocks::FakeConnection.new(true, channel) }

    let(:mock_channel) do
      ch = double('channel')
      allow(ch).to receive(:reject)
      allow(ch).to receive(:ack)
      allow(ch).to receive(:open?).and_return(true)
      default_ex = double('default_exchange')
      allow(default_ex).to receive(:publish)
      allow(ch).to receive(:default_exchange).and_return(default_ex)
      ch
    end

    let(:mock_session) do
      s = instance_double(BugBunny::Session)
      allow(s).to receive(:exchange).and_return(double('exchange'))
      allow(s).to receive(:queue).and_return(double('queue'))
      allow(s).to receive(:close)
      allow(s).to receive(:channel).and_return(mock_channel)
      s
    end

    let(:test_consumer) do
      c = BugBunny::Consumer.new(connection)
      c.instance_variable_set(:@session, mock_session)
      c
    end

    let(:delivery_info) do
      double('delivery_info',
             exchange: 'events_x',
             routing_key: 'users.created',
             delivery_tag: 'delivery-tag-1',
             redelivered?: false)
    end

    let(:properties) do
      double('properties',
             type: 'services/otaigccd59q0k7kxb1h193go2/restart',
             headers: { 'x-http-method' => 'GET' },
             correlation_id: 'corr-abc-123',
             reply_to: nil,
             content_type: 'application/json')
    end

    let(:logged_events) { [] }

    before do
      allow(test_consumer).to receive(:safe_log) do |level, event, **kwargs|
        logged_events << { level: level, event: event, kwargs: kwargs }
      end
      allow(test_consumer).to receive(:handle_fatal_error)
    end

    it 'logs route_not_found with normalized path (without extra slash)' do
      allow(BugBunny.routes).to receive(:recognize).and_return(nil)

      test_consumer.send(:process_message, delivery_info, properties, '{}')

      route_not_found_event = logged_events.find { |e| e[:event] == 'consumer.route_not_found' }
      expect(route_not_found_event).not_to be_nil
      expect(route_not_found_event[:kwargs][:path]).to eq('services/otaigccd59q0k7kxb1h193go2/restart')
    end

    context 'when properties.type has leading slash' do
      let(:properties) do
        double('properties',
               type: '/services/otaigccd59q0k7kxb1h193go2/restart',
               headers: { 'x-http-method' => 'GET' },
               correlation_id: 'corr-abc-123',
               reply_to: nil,
               content_type: 'application/json')
      end

      it 'logs route_not_found with normalized path (stripped leading slash)' do
        allow(BugBunny.routes).to receive(:recognize).and_return(nil)

        test_consumer.send(:process_message, delivery_info, properties, '{}')

        route_not_found_event = logged_events.find { |e| e[:event] == 'consumer.route_not_found' }
        expect(route_not_found_event).not_to be_nil
        expect(route_not_found_event[:kwargs][:path]).to eq('services/otaigccd59q0k7kxb1h193go2/restart')
      end
    end
  end
end
