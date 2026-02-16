# frozen_string_literal: true

# config/initializers/bug_bunny.rb

# 1. Configuración Global de Conexión (Credenciales)
BugBunny.configure do |config|
  config.host = ENV.fetch('RABBITMQ_HOST', 'localhost')
  config.vhost = ENV.fetch('RABBITMQ_VHOST', '/')
  config.username = ENV.fetch('RABBITMQ_USER', 'guest')
  config.password = ENV.fetch('RABBITMQ_PASS', 'guest')
  config.logger = Rails.logger
end

# 2. Crear el Pool de Conexiones (Vital para Puma/Sidekiq)
# Usamos una constante global o un singleton para mantener el pool vivo
BUG_BUNNY_POOL = ConnectionPool.new(size: ENV.fetch('RAILS_MAX_THREADS', 5).to_i, timeout: 5) do
  BugBunny.create_connection
end

# 3. Inyectar el Pool en los Recursos
# Así todos tus modelos (User, Invoice, etc.) usan este pool por defecto
BugBunny::Resource.connection_pool = BUG_BUNNY_POOL

# 4. (Opcional) Configurar Middlewares Globales
# Si en el futuro quieres que BugBunny::Resource use middlewares (logs, tracing),
# podrías inyectar un cliente pre-configurado en lugar del pool directo.
# Por ahora, con el pool es suficiente para la v1.0.

puts "🐰 BugBunny inicializado con Pool de #{BUG_BUNNY_POOL.size} conexiones."
