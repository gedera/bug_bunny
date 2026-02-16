# frozen_string_literal: true

# bin_client.rb
require 'bundler/setup'
require 'bug_bunny'

# 1. Configurar
BugBunny.configure do |config|
  config.logger = Logger.new($stdout)
  config.logger.level = Logger::INFO
end

# 2. Crear Pool de Conexiones
pool = BugBunny.create_connection_pool

# 3. Instanciar Cliente
client = BugBunny::Client.new(pool: pool)

puts '🚀 Enviando Petición RPC...'

begin
  # 4. Realizar Request Síncrono (RPC)
  # GET users/123/ping
  # Exchange: 'test_exchange' (Topic)
  # Routing Key: 'test.ping'
  #
  # Nota: El bloque opcional permite configurar el objeto Request antes de enviarlo
  response = client.request('test/123/ping', exchange: 'test_exchange',
                                             exchange_type: 'topic', routing_key: 'test.ping') do |req|
    req.headers['x-custom-token'] = 'secret-123'
    puts '    -> Request configurado (Headers custom agregados).'
  end

  puts '    -> Enviado.'

  # 5. Procesar Respuesta
  if response
    puts '    -> ✅ RESPUESTA RECIBIDA:'
    puts "       Status: #{response['status']}"
    puts "       Body:   #{response['body']}"
  end
rescue BugBunny::RequestTimeout
  puts '    -> ❌ Error: Timeout esperando respuesta.'
rescue StandardError => e
  puts "    -> ❌ Error: #{e.message}"
end
