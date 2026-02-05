# frozen_string_literal: true

# BugBunny Configuration
#
# Este archivo inicializador permite ajustar el comportamiento global de la conexión
# a RabbitMQ y los parámetros de rendimiento de los consumidores.
#
# Se recomienda encarecidamente utilizar variables de entorno (ENV) para gestionar
# las credenciales y evitar hardcodear secretos en el repositorio.

BugBunny.configure do |config|
  # ==========================================
  # 🔌 Conexión a RabbitMQ
  # ==========================================

  # Dirección IP o Hostname del servidor RabbitMQ.
  config.host = ENV.fetch('RABBITMQ_HOST', 'localhost')

  # Usuario para la autenticación (SASL).
  config.username = ENV.fetch('RABBITMQ_USERNAME', 'guest')

  # Contraseña del usuario.
  config.password = ENV.fetch('RABBITMQ_PASSWORD', 'guest')

  # Virtual Host (VHost) para aislar entornos (ej: '/', '/staging', '/prod').
  config.vhost = ENV.fetch('RABBITMQ_VHOST', '/')

  # ==========================================
  # 🛡️ Resiliencia y Recuperación
  # ==========================================

  # Si es true, la librería intentará reconectar automáticamente los canales
  # y recuperar las suscripciones si la conexión TCP se corta.
  config.automatically_recover = true

  # Tiempo de espera en segundos antes de intentar restablecer una conexión caída.
  config.network_recovery_interval = 5

  # ==========================================
  # ⏱️ Timeouts
  # ==========================================

  # Tiempo máximo en segundos para establecer la conexión TCP inicial.
  config.connection_timeout = 10

  # Timeout crítico para llamadas RPC síncronas (Resource.find, Client.request).
  # Si el worker remoto no responde dentro de este tiempo, el cliente lanzará
  # una excepción `BugBunny::RequestTimeout`.
  config.rpc_timeout = 10

  # ==========================================
  # 🚀 Rendimiento (QoS)
  # ==========================================

  # Channel Prefetch (QoS): Controla el "Backpressure".
  # Define cuántos mensajes sin confirmar (unacked) puede tener un consumidor al mismo tiempo.
  #
  # * Valor bajo (1): Garantiza distribución justa (Round Robin) entre workers, pero menor throughput.
  # * Valor alto (10-50): Mayor throughput, pero riesgo de sobrecargar un solo worker lento.
  config.channel_prefetch = 10
end
