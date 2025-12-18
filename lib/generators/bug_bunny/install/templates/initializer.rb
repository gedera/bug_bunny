# frozen_string_literal: true

BugBunny.configure do |config|
  # --- Conexión a RabbitMQ ---
  config.host = ENV.fetch('RABBITMQ_HOST', 'localhost')
  config.username = ENV.fetch('RABBITMQ_USERNAME', 'guest')
  config.password = ENV.fetch('RABBITMQ_PASSWORD', 'guest')
  config.vhost = ENV.fetch('RABBITMQ_VHOST', '/')

  # --- Resiliencia y Recuperación ---
  config.automatically_recover = true
  config.network_recovery_interval = 5 # segundos

  # --- Timeouts ---
  config.connection_timeout = 10
  config.rpc_timeout = 10 # Tiempo máximo de espera para respuestas síncronas

  # --- Rendimiento ---
  config.channel_prefetch = 10 # Cuántos mensajes procesar en paralelo por consumidor
end
