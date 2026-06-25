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

    # Alcance issue #52: status + raw_response como materia prima en TODAS las
    # clases de error, no solo en 422.
    describe 'raw_response and status on every error class' do
      def captured_error(response)
        middleware.on_complete(response)
        nil
      rescue BugBunny::Error => e
        e
      end

      {
        400 => BugBunny::BadRequest,
        409 => BugBunny::Conflict,
        500 => BugBunny::InternalServerError
      }.each do |status, klass|
        context "when status is #{status}" do
          let(:body) { { 'error' => 'boom' } }
          let(:error) { captured_error('status' => status, 'body' => body) }

          it "raises #{klass} with status and raw_response populated" do
            expect(error).to be_a(klass)
            expect(error.status).to eq(status)
            expect(error.raw_response).to eq(body)
          end
        end
      end

      context 'when status is 404 (NotFound)' do
        let(:body) { { 'error' => 'missing' } }
        let(:error) { captured_error('status' => 404, 'body' => body) }

        it 'populates status and raw_response' do
          expect(error.status).to eq(404)
          expect(error.raw_response).to eq(body)
        end
      end

      context 'when status is 422 (UnprocessableEntity)' do
        let(:body) { { 'errors' => { 'name' => ['blank'] } } }
        let(:error) { captured_error('status' => 422, 'body' => body) }

        it 'keeps raw_response/error_messages and adds status from base' do
          expect(error).to be_a(BugBunny::UnprocessableEntity)
          expect(error.status).to eq(422)
          expect(error.raw_response).to eq(body)
          expect(error.error_messages).to eq('name' => ['blank'])
        end
      end

      context 'when status is unmapped (418)' do
        let(:body) { { 'error' => 'teapot' } }
        let(:error) { captured_error('status' => 418, 'body' => body) }

        it 'populates status and raw_response on the generic ClientError' do
          expect(error).to be_a(BugBunny::ClientError)
          expect(error.status).to eq(418)
          expect(error.raw_response).to eq(body)
        end
      end
    end

    # Alcance issue #52: hardening de format_error_message contra el envelope
    # anidado para no volcar un Hash#inspect en .message.
    describe 'message hardening against the nested canonical envelope' do
      def captured_error(response)
        middleware.on_complete(response)
        nil
      rescue BugBunny::Error => e
        e
      end

      context 'when error is the nested canonical envelope { error: { message } }' do
        let(:body) { { 'error' => { 'code' => 'shortname_taken', 'message' => 'shortname already taken', 'details' => {} } } }
        let(:error) { captured_error('status' => 409, 'body' => body) }

        it 'extracts the human message and does not dump the Hash' do
          expect(error.message).to eq('shortname already taken')
          expect(error.message).not_to include('=>')
        end
      end

      context 'when the nested envelope lacks a usable message' do
        let(:body) { { 'error' => { 'code' => 'x', 'details' => {} } } }
        let(:error) { captured_error('status' => 409, 'body' => body) }

        it 'falls back to JSON instead of Hash#inspect' do
          expect(error.message).to eq(body.to_json)
          expect(error.message).not_to include('=>')
        end
      end

      context 'when error is the flat historical shape { error: string, detail: string }' do
        let(:body) { { 'error' => 'boom', 'detail' => 'because reasons' } }
        let(:error) { captured_error('status' => 400, 'body' => body) }

        it 'keeps concatenating error and detail (backward compatible)' do
          expect(error.message).to eq('boom - because reasons')
        end
      end

      context 'when error is an empty string (backward-compat edge case)' do
        let(:body) { { 'error' => '', 'detail' => 'x' } }
        let(:error) { captured_error('status' => 400, 'body' => body) }

        it 'preserves the historical concatenation instead of dumping JSON' do
          expect(error.message).to eq(' - x')
        end
      end
    end

    # Alcance issue #52: casos borde y paths no cubiertos arriba.
    describe 'edge cases and uncovered paths' do
      def captured_error(response)
        middleware.on_complete(response)
        nil
      rescue BugBunny::Error => e
        e
      end

      context 'when 5xx carries a serialized remote exception (bug_bunny_exception)' do
        let(:body) do
          { 'bug_bunny_exception' => { 'class' => 'ActiveRecord::RecordNotFound',
                                       'message' => 'User not found',
                                       'backtrace' => ['app.rb:1'] } }
        end
        let(:error) { captured_error('status' => 500, 'body' => body) }

        it 'raises RemoteError with status and raw_response populated' do
          expect(error).to be_a(BugBunny::RemoteError)
          expect(error.status).to eq(500)
          expect(error.raw_response).to eq(body)
          expect(error.original_class).to eq('ActiveRecord::RecordNotFound')
        end
      end

      context 'when 422 carries the nested envelope (consumer parses from raw_response)' do
        let(:body) { { 'error' => { 'code' => 'taken', 'message' => 'shortname already taken', 'details' => {} } } }
        let(:error) { captured_error('status' => 422, 'body' => body) }

        it 'keeps raw_response intact for the service boundary' do
          expect(error).to be_a(BugBunny::UnprocessableEntity)
          expect(error.status).to eq(422)
          expect(error.raw_response).to eq(body)
        end
      end

      context 'when status is 406 (no-arg constructor)' do
        let(:body) { { 'error' => 'nope' } }
        let(:error) { captured_error('status' => 406, 'body' => body) }

        it 'still populates status and raw_response' do
          expect(error).to be_a(BugBunny::NotAcceptable)
          expect(error.status).to eq(406)
          expect(error.raw_response).to eq(body)
        end
      end

      context 'when status is 408 (no-arg constructor)' do
        let(:error) { captured_error('status' => 408, 'body' => nil) }

        it 'still populates status' do
          expect(error).to be_a(BugBunny::RequestTimeout)
          expect(error.status).to eq(408)
        end
      end

      context 'when body is not a Hash nor a String (e.g. Array)' do
        let(:body) { [1, 2, 3] }
        let(:error) { captured_error('status' => 400, 'body' => body) }

        it 'falls back to JSON without raising in the formatter' do
          expect(error.message).to eq(body.to_json)
        end
      end
    end
  end
end
