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
    test_update_and_destroy
    test_scope_with
    test_remote_validation
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

  def test_update_and_destroy
    puts "\n  [4] Test Update & Destroy (PUT/DELETE)"

    # 1. Crear
    user = TestUser.create(name: 'Update Me', email: 'orig@test.com')
    original_id = user.id

    # 2. Actualizar
    puts '    -> Actualizando nombre...'
    user.name = 'Updated Name'
    assert(user.save, 'El update debería retornar true')
    assert(user.name == 'Updated Name', 'El objeto local debe estar actualizado')

    # 3. Eliminar
    puts '    -> Eliminando usuario...'
    assert(user.destroy, 'Destroy debería retornar true')
    assert(user.persisted? == false, 'El objeto debe marcarse como no persistido')

    # 4. Verificar que ya no existe (esperamos 404 -> nil)
    assert(TestUser.find(original_id).nil?, 'El usuario no debería encontrarse tras el destroy')

    puts '    ✅ PASS: Ciclo de vida completo (CRUD) exitoso.'
  end

  def test_scope_with
    puts "\n  [5] Test Scope .with (Contexto)"

    # Probamos que el contexto se aplica
    user = TestUser.with(routing_key: 'test_user.ping').find(123)

    # El find debería funcionar si la routing key es válida para el bind
    assert(user.is_a?(TestUser), 'El .with funcionó y trajo el usuario')

    # Verificar que el contexto NO se filtró (Thread safety)
    assert(TestUser.routing_key == 'test_user', 'La configuración global se mantuvo intacta')

    puts '    ✅ PASS: Scope .with aplicado y limpiado correctamente.'
  end

  def test_remote_validation
    puts "\n  [6] Test Validación Remota (422 Unprocessable Entity)"

    # Localmente es válido
    user = TestUser.new(name: 'Valid Local', email: 'fail@remote.org')
    assert(user.valid?, 'El usuario es válido localmente')

    # Remotamente falla
    puts '    -> Enviando usuario que el servidor rechazará...'
    result = user.save

    assert(result == false, 'Save debe retornar false ante un 422')
    assert(user.errors[:email].include?('no se permiten .org'), 'Los errores remotos se cargaron en el modelo local')

    puts '    ✅ PASS: Errores remotos (422) procesados correctamente.'
  end

  def test_local_validation
    puts "\n  [7] Test Validation (Client Side)"
    invalid_user = TestUser.new(email: 'sin@mail.com')
    assert(invalid_user.valid? == false, 'Usuario sin nombre es inválido')
    puts '    ✅ PASS: Validaciones locales funcionan.'
  end

  def test_timeout_handling
    puts "\n  [8] Test Timeout / Error Handling"
    pool = BugBunny.create_connection_pool
    client = BugBunny::Client.new(pool: pool)

    puts '    -> Intentando ruta incorrecta...'
    client.request('ruta/inexistente', timeout: 1)
    assert(false, 'Debería haber fallado por timeout')
  rescue BugBunny::RequestTimeout, BugBunny::ClientError
    puts '    ✅ PASS: Error/Timeout capturado correctamente.'
  end

  def test_where_query
    puts "\n  [9] Test .where (Query Params)"
    users = TestUser.where(name: 'Gabo')
    assert(users.is_a?(Array), 'Devuelve un array')
    puts '    ✅ PASS: .where ejecutado correctamente.'
  end
end

# Ejecutar la suite
IntegrationSuite.new.run
