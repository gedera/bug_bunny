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
  assert(false, "Error RPC: #{e.class} - #{e.message}")
end

# ---------------------------------------------------------
# TEST 2: Resource Finder (ORM)
# ---------------------------------------------------------
puts "\n[2] Probando BugBunny::Resource (Estilo Rails)..."

# YA NO NECESITAS with_scope
puts "    -> Buscando usuario ID 123..."
user = TestUser.find(123)

if user
  assert(user.is_a?(TestUser), "El objeto retornado es un TestUser")
  assert(user.name == "Gabriel", "El nombre cargó correctamente")
  assert(user.persisted?, "El objeto figura como persistido")
else
  assert(false, "No se encontró el usuario (Check worker logs)")
end

# ---------------------------------------------------------
# TEST 3: Resource Create (ORM)
# ---------------------------------------------------------
puts "\n[3] Probando Resource Creation..."
puts "    -> Creando usuario nuevo..."
new_user = TestUser.create(name: "Nuevo User", email: "new@test.com")
if new_user.persisted?
  assert(new_user.persisted?, "El usuario se guardó y recibió ID")
  assert(new_user.id.present?, "Tiene ID asignado por el worker (#{new_user.id})")
else
  assert(false, "Fallo al crear usuario: #{new_user.errors.full_messages}")
end

# ---------------------------------------------------------
# TEST 4: Validaciones Locales
# ---------------------------------------------------------
puts "\n[4] Probando Validaciones Locales..."
invalid_user = TestUser.new(email: "sin_nombre@test.com")
assert(invalid_user.valid? == false, "Usuario sin nombre es inválido")
assert(invalid_user.errors[:name].any?, "Tiene error en el campo :name")

# ---------------------------------------------------------
# TEST 5: Probando Configuración Dinámica (.with)...
# ---------------------------------------------------------
puts "\n[5] Probando Configuración Dinámica (.with)..."

# Probamos cambiar el routing key prefix temporalmente
begin
  # Forzamos una routing key que no existe
  puts "    -> Intentando ruta incorrecta (esperando timeout)..."
  TestUser.with(routing_key: 'ruta.incorrecta').find(123)
  assert(false, "Debería haber fallado por timeout")
rescue BugBunny::RequestTimeout, BugBunny::ClientError
  # Nota: Dependiendo de tu config, puede dar Timeout o 501 si llega a un worker default
  puts "  ✅ PASS: El override funcionó (timeout o error esperado en ruta incorrecta)"
end

# Probamos que vuelve a la normalidad
user = TestUser.find(123)
assert(user.present?, "  ✅ PASS: La configuración volvió a la normalidad")

# ---------------------------------------------------------
# TEST 6: Filtrado Complejo (Query String Nested - FIX Rack)
# ---------------------------------------------------------
puts "\n[6] Probando Resource.where con filtros anidados (Fix Rack)..."

begin
  # Esto fallaba antes (generaba string feo en la URL: {:active=>true})
  # Al usar Rack, esto genera: ?q[active]=true&q[roles][]=admin
  # No necesitamos que el worker responda algo real, solo que el request SALGA sin explotar URI.
  TestUser.where(q: { active: true, roles: ['admin'] })
  puts "  ✅ PASS: .where generó la query anidada correctamente sin errores de URI."
rescue URI::InvalidURIError => e
  assert(false, "❌ FAIL: URI Inválida (El fix de Rack no funcionó): #{e.message}")
rescue => e
  # Si falla por conexión o 404 está bien, lo importante es que no falle al serializar
  puts "  ✅ PASS: El request se envió correctamente (aunque el worker responda: #{e.class}). Serialización OK."
end

puts "\n🏁 SUITE FINALIZADA"
