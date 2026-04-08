# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BugBunny::Middleware::RaiseError do
  subject(:middleware) { described_class.new(->(_env) { {} }) }

  describe '#on_complete' do
    context 'when status is 404 with error_type routing_error' do
      let(:response) do
        {
          'status' => 404,
          'body' => { 'error' => 'Not Found', 'detail' => 'No route matches [GET] "secrets"',
                      'error_type' => 'routing_error' }
        }
      end

      it 'raises BugBunny::RoutingError' do
        expect { middleware.on_complete(response) }.to raise_error(BugBunny::RoutingError)
      end

      it 'includes the detail in the error message' do
        expect { middleware.on_complete(response) }.to raise_error(
          BugBunny::RoutingError, /No route matches \[GET\] "secrets"/
        )
      end

      it 'is rescuable as BugBunny::NotFound' do
        expect { middleware.on_complete(response) }.to raise_error(BugBunny::NotFound)
      end
    end

    context 'when status is 404 without error_type (resource not found)' do
      let(:response) do
        { 'status' => 404, 'body' => { 'error' => 'Not Found', 'detail' => 'User 999 not found' } }
      end

      it 'raises BugBunny::NotFound but not RoutingError' do
        error = nil
        begin
          middleware.on_complete(response)
        rescue BugBunny::NotFound => e
          error = e
        end

        expect(error).to be_a(BugBunny::NotFound)
        expect(error).not_to be_a(BugBunny::RoutingError)
      end
    end

    context 'when status is 404 with nil body' do
      let(:response) { { 'status' => 404, 'body' => nil } }

      it 'raises BugBunny::NotFound' do
        expect { middleware.on_complete(response) }.to raise_error(BugBunny::NotFound)
      end
    end
  end
end
