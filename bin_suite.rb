# bin_suite.rb
require_relative 'test_helper'
require_relative 'test_resource' # Cargamos la clase TestUser

# Cliente "Raw" para pruebas manuales
raw_client = BugBunny.new(pool: TEST_POOL)

def assert(condition, msg)
  if condition
    puts "  ✅ PASS: #{msg}"
  else
    puts "  ❌ FAIL: #{msg}"
  end
end

puts "\n🔎 --- INICIANDO SUITE DE PRUEBAS BUG BUNNY ---"

# ---------------------------------------------------------
# TEST 1: RPC Manual (Raw Client)
# ---------------------------------------------------------
puts "\n[1] Probando RPC Manual (Client#request)..."
begin
  # Notar la routing key: test_user.ping
  response = raw_client.request('test_user/ping', exchange: 'test_exchange', exchange_type: 'topic', routing_key: 'test_user.ping')
  assert(response['body']['message'] == 'Pong!', "Respuesta RPC recibida correctamente")
rescue => e
  assert(false, "Error RPC: #{e.message}")
end

# ---------------------------------------------------------
# TEST 2: Resource Finder (ORM)
# ---------------------------------------------------------
puts "\n[2] Probando BugBunny::Resource (Estilo Rails)..."

# YA NO NECESITAS with_scope
puts "    -> Buscando usuario ID 123..."
user = TestUser.find(123)

assert(user.is_a?(TestUser), "El objeto retornado es un TestUser")
assert(user.name == "Gabriel", "El nombre cargó correctamente")
assert(user.persisted?, "El objeto figura como persistido")
# ---------------------------------------------------------
# TEST 3: Resource Create (ORM)
# ---------------------------------------------------------
puts "\n[3] Probando Resource Creation..."
puts "    -> Creando usuario nuevo..."
new_user = TestUser.create(name: "Nuevo User", email: "new@test.com")
assert(new_user.persisted?, "El usuario se guardó y recibió ID")
assert(new_user.id.present?, "Tiene ID asignado por el worker (#{new_user.id})")

# ---------------------------------------------------------
# TEST 4: Validaciones Locales
# ---------------------------------------------------------
puts "\n[4] Probando Validaciones Locales..."
invalid_user = TestUser.new(email: "sin_nombre@test.com")
assert(invalid_user.valid? == false, "Usuario sin nombre es inválido")
assert(invalid_user.errors[:name].any?, "Tiene error en el campo :name")

puts "\n🏁 SUITE FINALIZADA"

# ---------------------------------------------------------
# TEST 5: Probando Configuración Dinámica (.with)...
# ---------------------------------------------------------
puts "\n[5] Probando Configuración Dinámica (.with)..."

# Probamos cambiar el routing key prefix temporalmente
# El worker escucha 'test_user.*', así que si cambiamos a 'bad_prefix', debería fallar o no encontrar nada
begin
  # Forzamos una routing key que no existe para ver si respeta el cambio
  TestUser.with(routing_key: 'ruta.incorrecta').find(123)
rescue BugBunny::RequestTimeout
  puts "  ✅ PASS: El override funcionó (timeout esperado en ruta incorrecta)"
end

# Probamos que vuelve a la normalidad
user = TestUser.find(123)
assert(user.present?, "  ✅ PASS: La configuración volvió a la normalidad")
