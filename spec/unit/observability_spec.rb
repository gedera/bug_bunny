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

  describe '.redact_value (contenido sensible en texto libre)' do
    # Complementa a .sensitive_key?: esa mira el NOMBRE de la clave, esta el
    # CONTENIDO. El caso que motiva la feature es el `message` de una excepción.
    it 'redacta un Bearer token' do
      redacted = BugBunny::Observability.redact_value(
        'undefined method for #<Faraday::Response headers={"Authorization"=>"Bearer eyJhbGciOiJIUzI1NiJ9.abc"}>'
      )

      expect(redacted).not_to include('eyJhbGciOiJIUzI1NiJ9.abc')
      expect(redacted).to include('[FILTERED]')
    end

    it 'redacta un esquema Basic' do
      redacted = BugBunny::Observability.redact_value('Authorization: Basic dXNlcjpwYXNzd29yZA==')

      expect(redacted).not_to include('dXNlcjpwYXNzd29yZA')
      expect(redacted).to include('[FILTERED]')
    end

    it 'redacta el valor cuando la key viaja DENTRO del texto, conservando el nombre' do
      redacted = BugBunny::Observability.redact_value('connect failed (token=abc123, host=rabbit)')

      expect(redacted).not_to include('abc123')
      expect(redacted).to include('token=[FILTERED]')
      # El resto del mensaje sobrevive: la redacción es quirúrgica, no destructiva.
      expect(redacted).to include('host=rabbit')
    end

    it 'matchea la key más larga primero (authorization no se parte en auth)' do
      redacted = BugBunny::Observability.redact_value('authorization: "Bearer-less-secret-value"')

      expect(redacted).not_to include('Bearer-less-secret-value')
      expect(redacted).to include('authorization=[FILTERED]')
    end

    it 'redacta credenciales de una URL conservando esquema y host' do
      redacted = BugBunny::Observability.redact_value('amqp://guest:s3cr3t@rabbit:5672/vhost')

      expect(redacted).not_to include('s3cr3t')
      expect(redacted).to include('amqp://[FILTERED]@rabbit:5672/vhost')
    end

    it 'deja intacto un texto sin credenciales' do
      expect(BugBunny::Observability.redact_value('timeout after 30s on queue acs.rpc'))
        .to eq('timeout after 30s on queue acs.rpc')
    end

    it 'no confunde una key no sensible que contiene un substring parecido' do
      expect(BugBunny::Observability.redact_value('passport_number=AB123'))
        .to include('AB123')
    end

    # `_` es word-char: un `\b` antes de la key NO encuentra borde dentro de
    # `access_token` ni de `accessToken`, y esas variantes se colaban en claro.
    # Son exactamente las que sensitive_key? cubre a propósito con substring matching.
    it 'redacta la variante con separador (access_token) conservando el nombre completo' do
      redacted = BugBunny::Observability.redact_value('request failed access_token=eyJsecret.jwt')

      expect(redacted).not_to include('eyJsecret.jwt')
      expect(redacted).to include('access_token=[FILTERED]')
    end

    it 'redacta la variante con prefijo (user_password)' do
      redacted = BugBunny::Observability.redact_value('invalid params user_password=hunter2')

      expect(redacted).not_to include('hunter2')
      expect(redacted).to include('user_password=[FILTERED]')
    end

    it 'redacta la variante camelCase (accessToken)' do
      redacted = BugBunny::Observability.redact_value('boom accessToken=eyJsecret.jwt')

      expect(redacted).not_to include('eyJsecret.jwt')
      expect(redacted).to include('accessToken=[FILTERED]')
    end

    it 'no redacta una key no sensible con sufijo numérico (processing_session_count)' do
      expect(BugBunny::Observability.redact_value('processing_session_count=5'))
        .to eq('processing_session_count=5')
    end
  end

  describe '.redact_structure (estructura antes de serializar)' do
    it 'redacta por key interna y deja la forma intacta' do
      redacted = BugBunny::Observability.redact_structure(
        'token' => 'abc123', 'host' => 'rabbit'
      )

      expect(redacted).to eq('token' => '[FILTERED]', 'host' => 'rabbit')
    end

    it 'recorre Hash anidado y Array' do
      redacted = BugBunny::Observability.redact_structure(
        'nested' => { 'api_key' => 'xyz', 'n' => 1 },
        'list' => ['token=abc123', 'clean']
      )

      expect(redacted).to eq(
        'nested' => { 'api_key' => '[FILTERED]', 'n' => 1 },
        'list' => ['token=[FILTERED]', 'clean']
      )
    end

    it 'no altera numéricos ni booleanos ni nil' do
      expect(BugBunny::Observability.redact_structure('n' => 1, 'ok' => true, 'x' => nil))
        .to eq('n' => 1, 'ok' => true, 'x' => nil)
    end
  end

  describe '#safe_log — redacción por contenido' do
    # El caso real: el nombre de la clave NO es sensible (`reason`), así que el
    # filtro por-clave lo deja pasar; la credencial va en el valor.
    it 'filtra una credencial embebida en el valor de una key NO sensible' do
      host.safe_log(:error, 'unhandled_exception',
                    reason: 'NoMethodError on headers {"Authorization"=>"Bearer eyJsupersecret.jwt"}')

      expect(last_log_line).not_to include('eyJsupersecret.jwt')
      expect(last_log_line).to include('[FILTERED]')
    end

    it 'filtra dentro de un Hash serializado (las keys internas no pasan por sensitive_key?)' do
      host.safe_log(:error, 'unhandled_exception', details: { 'token' => 'abc123xyz' })

      expect(last_log_line).not_to include('abc123xyz')
      expect(last_log_line).to include('[FILTERED]')
    end

    # La redacción no puede costar la estructura: quien consume el log parsea este campo
    # como JSON, y un objeto roto le hace perder TODOS los pares, no solo el redactado.
    it 'mantiene el campo Hash como JSON parseable después de redactar' do
      host.safe_log(:error, 'unhandled_exception',
                    details: { 'token' => 'abc123xyz', 'host' => 'rabbit',
                               'nested' => { 'api_key' => 'xyz789', 'n' => 1 } })

      field = last_log_line[/details=(\S+)/, 1]

      expect { JSON.parse(field) }.not_to raise_error
      expect(JSON.parse(field)).to eq(
        'token' => '[FILTERED]', 'host' => 'rabbit',
        'nested' => { 'api_key' => '[FILTERED]', 'n' => 1 }
      )
    end

    it 'no altera un valor numérico' do
      host.safe_log(:info, 'done', duration_s: 1.5, status: 200)

      expect(last_log_line).to include('duration_s=1.5', 'status=200')
    end

    it 'preserva el resto de la línea (component, event y campos limpios)' do
      host.safe_log(:error, 'request_error', kind: 'unavailable', reason: 'ACS down')

      line = last_log_line
      expect(line).to include('event=request_error', 'kind=unavailable')
      expect(line).to include('reason="ACS down"')
    end
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
