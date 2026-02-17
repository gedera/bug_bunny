# frozen_string_literal: true

# bin_worker.rb
require 'bundler/setup'
require 'bug_bunny'
require_relative 'test_controller' # Cargamos los controladores

puts '🐰 WORKER INICIADO (Exchange: Topic)...'

# Configuración básica
BugBunny.configure do |config|
  config.logger = Logger.new($stdout)
  config.logger.level = Logger::DEBUG
end

# Iniciar el Consumidor
# Escucha en la cola 'bug_bunny_queue', atada al exchange 'test_exchange' con routing key '#' (todo)
connection = BugBunny.create_connection

BugBunny::Consumer.subscribe(
  connection: connection,
  exchange_name: 'test_exchange',
  exchange_type: 'topic',
  queue_name: 'bug_bunny_test_queue',
  routing_key: '#' # Wildcard para recibir todo en este test
)
