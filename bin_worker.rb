# bin_worker.rb
require_relative 'test_controller'
$stdout.sync = true # <--- Agrega esto para ver logs instantáneos

BugBunny.configure do |config|
  config.host = 'localhost'
  config.username = 'wisproMQ'
  config.password = 'wisproMQ'
  config.vhost = 'sync.devel'
  config.logger = Logger.new(STDOUT)
end

puts "🐰 Iniciando Worker de BugBunny..."

connection = BugBunny.create_connection
consumer = BugBunny::Consumer.new(connection)

puts " [*] Esperando mensajes en 'test_queue'. CTRL+C para salir."

begin
  consumer.subscribe(
    queue_name: 'test_queue',
    exchange_name: 'test_exchange',
    exchange_type: 'topic', # <--- CAMBIO IMPORTANTE: 'topic' para usar comodines
    routing_key: 'test.*'   # Ahora sí funcionará con 'test.ping', 'test.pong', etc.
  )
rescue Interrupt
  connection.close
  puts "\nAdiós!"
end
