module BugBunny
  # Clase de soporte para mantener la conexión global de Rails (Singleton).
  # También actúa como punto de entrada helper para iniciar Consumidores.
  #
  # NOTA: No usar esta clase para publicar mensajes.
  # Para publicar, usar: BugBunny::Client.new(pool: ...).request(...)
  class Rabbit
    class << self
      attr_writer :connection

      # Singleton de la conexión cruda (Bunny::Session)
      def connection
        return @connection if @connection&.open?

        @connection = create_connection
      end

      # Método delegado al helper principal para evitar duplicar configuración
      def create_connection
        BugBunny.create_connection
      end

      # Cierra la conexión global. Usado por Railtie en Puma/Spring.
      def disconnect
        return unless @connection

        @connection.close if @connection.open?
        @connection = nil
        BugBunny.configuration.logger.info("[BugBunny] Global connection closed.")
      end

      # Helper para iniciar un consumidor (Worker) de forma sencilla.
      # @param connection [Bunny::Session] Conexión dedicada para el consumidor
      def run_consumer(connection:, exchange:, exchange_type:, queue_name:, routing_key:, queue_opts: {})
        # 1. Instanciamos el Consumidor (que crea su propia Session interna)
        consumer = BugBunny::Consumer.new(connection)

        # 2. Iniciamos la suscripción (Bloqueante)
        consumer.subscribe(
          queue_name: queue_name,
          exchange_name: exchange,
          exchange_type: exchange_type,
          routing_key: routing_key,
          queue_opts: queue_opts
        )
      end
    end
  end
end
