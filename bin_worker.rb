# bin_worker.rb
require_relative 'test_helper'
require_relative 'test_controller'

puts "🐰 WORKER INICIADO (Exchange: Topic)..."

# Creamos la conexión (o usamos una del pool si quisieras)
connection = BugBunny.create_connection

# Usamos el método de clase directo.
# Al no pasar 'block: false', esto bloqueará la ejecución aquí mismo eternamente.
BugBunny::Consumer.subscribe(
  connection: connection,
  queue_name: 'test_users_queue',
  exchange_name: 'test_exchange',
  exchange_type: 'topic',
  routing_key: 'test_user.#'
)

# ¡Ya no necesitas el loop! El subscribe mantiene vivo el proceso.
