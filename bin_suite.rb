# frozen_string_literal: true

require 'bundler/setup'
require 'bug_bunny'
require 'test/unit'
require_relative 'test_resource'

# Envolvemos la suite en una clase para evitar 'Style/MixinUsage'
class IntegrationSuite
  include Test::Unit::Assertions

  def run
    setup_logger
    puts "\n🚀 INICIANDO TEST SUITE (Integration Tests)...\n"

    test_rpc_raw
    test_resource_find
    test_create
    test_local_validation
    test_timeout_handling
    test_where_query

    puts "\n✨ SUITE FINALIZADA ✨"
  end

  private

  def setup_logger
    BugBunny.configure do |config|
      config.logger = Logger.new($stdout)
      config.logger.level = Logger::WARN
    end
  end

  def test_rpc_raw
    puts '  [1] Test RPC Raw (Client -> Consumer)'
    pool = BugBunny.create_connection_pool
    client = BugBunny::Client.new(pool: pool)

    response = client.request('test_user/ping', exchange: 'test_exchange',
                                                exchange_type: 'topic', routing_key: 'test_user.ping')
    assert(response['body']['message'] == 'Pong!', 'Respuesta RPC recibida correctamente')
    puts '    ✅ PASS: Ping/Pong exitoso.'
  end

  def test_resource_find
    puts "\n  [2] Test Resource (User.find)"
    puts '    -> Buscando usuario ID 123...'
    user = TestUser.find(123)

    assert(user.is_a?(TestUser), 'El objeto retornado es un TestUser')
    assert(user.name == 'Gabriel', 'El nombre cargó correctamente')
    assert(user.persisted?, 'El objeto figura como persistido')
    puts "    ✅ PASS: Usuario encontrado: #{user.name}"
  rescue StandardError
    assert(false, 'Falló User.find')
  end

  def test_create
    puts "\n  [3] Test Create (User.create)"
    new_user = TestUser.create(name: 'Nuevo User', email: 'new@test.com')
    assert(new_user.persisted?, 'El usuario se guardó y recibió ID')
    puts "    ✅ PASS: Usuario creado con ID: #{new_user.id}"
  end

  def test_local_validation
    puts "\n  [4] Test Validation (Client Side)"
    invalid_user = TestUser.new(email: 'sin@mail.com')
    assert(invalid_user.valid? == false, 'Usuario sin nombre es inválido')
    puts '    ✅ PASS: Validaciones locales funcionan.'
  end

  def test_timeout_handling
    puts "\n  [5] Test Timeout / Error Handling"
    pool = BugBunny.create_connection_pool
    client = BugBunny::Client.new(pool: pool)

    puts '    -> Intentando ruta incorrecta...'
    client.request('ruta/inexistente', timeout: 1)
    assert(false, 'Debería haber fallado por timeout')
  rescue BugBunny::RequestTimeout, BugBunny::ClientError
    puts '    ✅ PASS: Error/Timeout capturado correctamente.'
  end

  def test_where_query
    puts "\n  [6] Test .where (Query Params)"
    users = TestUser.where(name: 'Gabo')
    assert(users.is_a?(Array), 'Devuelve un array')
    puts '    ✅ PASS: .where ejecutado correctamente.'
  end
end

# Ejecutar la suite
IntegrationSuite.new.run
