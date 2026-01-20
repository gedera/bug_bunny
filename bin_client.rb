# bin_client.rb
require_relative 'lib/bug_bunny'
$stdout.sync = true # <--- Agrega esto

# 1. Configuración
BugBunny.configure do |config|
  config.host = 'localhost'
  config.username = 'wisproMQ'
  config.password = 'wisproMQ'
  config.vhost = 'sync.devel'
  config.logger = Logger.new(STDOUT)
  config.rpc_timeout = 5
end

# 2. Pool
POOL = ConnectionPool.new(size: 2, timeout: 5) do
  BugBunny.create_connection
end

# 3. Cliente
client = BugBunny.new(pool: POOL)

# --- PRUEBA 1: Publish ---
puts "\n[1] Enviando mensaje asíncrono (Publish)..."

# AGREGADO: exchange_type: 'topic'
client.publish('test/ping', exchange: 'test_exchange', exchange_type: 'topic', routing_key: 'test.ping') do |req|
  req.body = { msg: 'Hola, soy invisible' }
end

puts "    -> Enviado."
sleep 1

# --- PRUEBA 2: RPC ---
puts "\n[2] Enviando petición síncrona (Request)..."

begin
  # AGREGADO: exchange_type: 'topic'
  response = client.request('test/123/ping', exchange: 'test_exchange', exchange_type: 'topic', routing_key: 'test.ping') do |req|
    req.body = { data: 'Importante' }
    req.timeout = 3
    req.headers['X-Source'] = 'Terminal'
  end

  puts "    -> ✅ RESPUESTA RECIBIDA:"
  puts "       Status: #{response['status']}"
  puts "       Body:   #{response['body']}"

rescue BugBunny::RequestTimeout
  puts "    -> ❌ Error: Timeout esperando respuesta."
end
