# frozen_string_literal: true

require 'spec_helper'
require 'logger'

RSpec.describe BugBunny::Observability do
  # Host class mínimo para ejercitar el mixin.
  let(:host_class) do
    Class.new do
      include BugBunny::Observability

      attr_writer :logger

      def initialize(logger)
        @logger = logger
      end

      # Expone safe_log públicamente solo para tests.
      public :safe_log
    end
  end

  let(:log_output) { StringIO.new }
  let(:logger)     { Logger.new(log_output) }
  let(:host)       { host_class.new(logger) }

  # Extrae el mensaje del log (después del prefijo "D, [timestamp] DEBUG -- :")
  def last_log_line
    log_output.string.split("\n").last.to_s.sub(/\A.*?:\s*/, '')
  end

  describe '.sensitive_key? (módulo público)' do
    subject(:sensitive?) { BugBunny::Observability.method(:sensitive_key?) }

    context 'keys símbolo' do
      it 'filtra :password' do
        expect(BugBunny::Observability.sensitive_key?(:password)).to be(true)
      end

      it 'filtra :token' do
        expect(BugBunny::Observability.sensitive_key?(:token)).to be(true)
      end

      it 'filtra :secret' do
        expect(BugBunny::Observability.sensitive_key?(:secret)).to be(true)
      end

      it 'filtra :api_key' do
        expect(BugBunny::Observability.sensitive_key?(:api_key)).to be(true)
      end

      it 'filtra :auth' do
        expect(BugBunny::Observability.sensitive_key?(:auth)).to be(true)
      end
    end

    context 'keys string' do
      it 'filtra "password"' do
        expect(BugBunny::Observability.sensitive_key?('password')).to be(true)
      end

      it 'filtra "Authorization" (case-insensitive)' do
        expect(BugBunny::Observability.sensitive_key?('Authorization')).to be(true)
      end

      it 'filtra "X-Api-Key" (case-insensitive)' do
        expect(BugBunny::Observability.sensitive_key?('X-Api-Key')).to be(true)
      end
    end

    context 'partial matches' do
      it 'filtra "user_password"' do
        expect(BugBunny::Observability.sensitive_key?('user_password')).to be(true)
      end

      it 'filtra "access_token"' do
        expect(BugBunny::Observability.sensitive_key?('access_token')).to be(true)
      end

      it 'filtra "refresh_token"' do
        expect(BugBunny::Observability.sensitive_key?('refresh_token')).to be(true)
      end

      it 'filtra "accessToken" (camelCase)' do
        expect(BugBunny::Observability.sensitive_key?('accessToken')).to be(true)
      end

      it 'filtra "password2"' do
        expect(BugBunny::Observability.sensitive_key?('password2')).to be(true)
      end

      it 'filtra "csrf_token"' do
        expect(BugBunny::Observability.sensitive_key?('csrf_token')).to be(true)
      end

      it 'filtra "csrftoken"' do
        expect(BugBunny::Observability.sensitive_key?('csrftoken')).to be(true)
      end

      it 'filtra "db_credentials"' do
        expect(BugBunny::Observability.sensitive_key?('db_credentials')).to be(true)
      end

      it 'filtra "private_key"' do
        expect(BugBunny::Observability.sensitive_key?('private_key')).to be(true)
      end

      it 'filtra "session_id"' do
        expect(BugBunny::Observability.sensitive_key?('session_id')).to be(true)
      end
    end

    context 'sin falsos positivos' do
      it 'no filtra "username"' do
        expect(BugBunny::Observability.sensitive_key?('username')).to be(false)
      end

      it 'no filtra "user_email"' do
        expect(BugBunny::Observability.sensitive_key?('user_email')).to be(false)
      end

      it 'no filtra "passport_number"' do
        expect(BugBunny::Observability.sensitive_key?('passport_number')).to be(false)
      end

      it 'no filtra "status"' do
        expect(BugBunny::Observability.sensitive_key?('status')).to be(false)
      end

      it 'no filtra "duration_s"' do
        expect(BugBunny::Observability.sensitive_key?('duration_s')).to be(false)
      end
    end
  end

  describe '#safe_log — filtrado en el output' do
    it 'reemplaza el valor de una key sensible con [FILTERED]' do
      host.safe_log(:info, 'test.event', password: 'secret123')
      expect(last_log_line).to include('password=[FILTERED]')
      expect(last_log_line).not_to include('secret123')
    end

    it 'filtra keys string sensibles' do
      host.safe_log(:info, 'test.event', 'Authorization' => 'Bearer xyz')
      expect(last_log_line).to include('Authorization=[FILTERED]')
      expect(last_log_line).not_to include('Bearer xyz')
    end

    it 'filtra partial match en key' do
      host.safe_log(:info, 'test.event', user_password: 'hunter2')
      expect(last_log_line).to include('user_password=[FILTERED]')
    end

    it 'no filtra keys no sensibles' do
      host.safe_log(:info, 'test.event', username: 'gabriel')
      expect(last_log_line).to include('username=gabriel')
    end

    it 'filtra múltiples keys sensibles en el mismo log' do
      host.safe_log(:info, 'test.event', token: 'abc', status: 'ok', secret: 'xyz')
      line = last_log_line
      expect(line).to include('token=[FILTERED]')
      expect(line).to include('secret=[FILTERED]')
      expect(line).to include('status=ok')
    end
  end
end
