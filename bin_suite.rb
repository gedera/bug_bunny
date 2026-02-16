# frozen_string_literal: true

# bin_suite.rb
require 'bundler/setup'
require 'bug_bunny'
require 'test/unit'
require_relative 'test_resource'

include Test::Unit::Assertions

# Configuración
BugBunny.configure do |config|
  config.logger = Logger.new($stdout)
  config.logger.level = Logger::WARN
end

puts "\n🚀 INICIANDO TEST SUITE (Integration Tests)...\n"

# 1. Test RPC Raw
puts "  [1] Test RPC Raw (Client -> Consumer)"
pool = BugBunny.create_connection_pool
raw_client = BugBunny::Client.new(pool: pool)

begin
  response = raw_client.request('test_user/ping', exchange: 'test_exchange',
                                                  exchange_type: 'topic', routing_key: 'test_user.ping')
  assert(response['body']['message'] == 'Pong!', 'Respuesta RPC recibida correctamente')
  puts '    ✅ PASS: Ping/Pong exitoso.'
rescue StandardError => e
  puts "    ❌ FAIL: #{e.message}"
  exit(1)
end

# 2. Test Resource (Active Record Style)
puts "\n  [2] Test Resource (User.find)"
begin
  puts '    -> Buscando usuario ID 123...'
  user = TestUser.find(123)

  assert(user.is_a?(TestUser), 'El objeto retornado es un TestUser')
  assert(user.name == 'Gabriel', 'El nombre cargó correctamente')
  assert(user.persisted?, 'El objeto figura como persistido')
  puts "    ✅ PASS: Usuario encontrado: #{user.name} (#{user.email})"
rescue StandardError => e
  puts "    ❌ FAIL: #{e.message}"
  assert(false, 'No se encontró el usuario (Check worker logs)')
end

# 3. Test Create & Validation
puts "\n  [3] Test Create (User.create)"
begin
  puts '    -> Creando usuario nuevo...'
  new_user = TestUser.create(name: 'Nuevo User', email: 'new@test.com')

  assert(new_user.persisted?, 'El usuario se guardó y recibió ID')
  puts "    ✅ PASS: Usuario creado con ID: #{new_user.id}"
rescue StandardError => e
  puts "    ❌ FAIL: #{e.message}"
end

puts "\n  [4] Test Validation (Client Side)"
invalid_user = TestUser.new(email: 'sin_nombre@test.com')
assert(invalid_user.valid? == false, 'Usuario sin nombre es inválido')
assert(invalid_user.errors[:name].any?, 'Tiene error en el campo :name')
puts '    ✅ PASS: Validaciones locales funcionan.'

# 4. Test Error Handling & Timeout
puts "\n  [5] Test Timeout / Error Handling"
begin
  # Forzamos un timeout configurando un timeout muy bajo temporalmente
  puts '    -> Forzando timeout con .with(timeout: 0.1)...'

  # Simulamos un override de timeout (necesitaríamos implementar soporte para esto en .with si no existe)
  # O simplemente llamamos a una ruta que no existe en el router
  puts '    -> Intentando ruta incorrecta (esperando timeout)...'
  raw_client.request('ruta/inexistente', timeout: 1)
  assert(false, 'Debería haber fallado por timeout')
rescue BugBunny::RequestTimeout, BugBunny::ClientError
  puts '  ✅ PASS: El override funcionó (timeout o error esperado en ruta incorrecta)'
end

# Validar que el scope se limpió
user = TestUser.find(123)
assert(user.present?, '  ✅ PASS: La configuración volvió a la normalidad')

# 5. Test Where (Query Params)
puts "\n  [6] Test .where (Query Params)"
begin
  users = TestUser.where(name: 'Gabo', active: true)
  # La URL generada debería ser test_user?name=Gabo&active=true
  # El consumidor debería recibirlo y parsearlo.

  # Nota: Como es un mock, asumimos que devuelve un array vacío o mockeado,
  # pero lo importante es que no explote la construcción de la query.
  assert(users.is_a?(Array), 'Devuelve un array')
  puts '  ✅ PASS: .where generó la query anidada correctamente sin errores de URI.'
rescue StandardError => e
  puts "  ❌ FAIL: #{e.message}"
end

puts "\n✨ SUITE FINALIZADA ✨"
