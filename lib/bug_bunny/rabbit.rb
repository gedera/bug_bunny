# frozen_string_literal: true

# lib/bug_bunny/rabbit.rb

module BugBunny
  # Clase de soporte e infraestructura para gestionar la conexión global de la aplicación.
  #
  # Actúa como un Singleton que mantiene una instancia de `Bunny::Session`.
  # Es utilizada principalmente por tareas administrativas (Rake tasks), inicializadores
  # y para lanzar consumidores (Workers).
  #
  # @note ¡IMPORTANTE!
  #   No utilizar esta clase para publicar mensajes desde controladores o servicios web.
  #   Esta clase mantiene una sola conexión TCP. Para publicar en entornos concurrentes (Puma/Sidekiq),
  #   se debe utilizar siempre {BugBunny::Client} inyectándole un `ConnectionPool`.
  class Rabbit
    class << self
      # Permite inyectar una conexión manualmente (útil para tests).
      # @api private
      attr_writer :connection

      # Obtiene la conexión global actual (Singleton).
      #
      # Implementa "Lazy Initialization": si la conexión no existe o está cerrada,
      # crea una nueva automáticamente.
      #
      # @return [Bunny::Session] La sesión cruda de Bunny.
      def connection
        return @connection if @connection&.open?

        @connection = create_connection
      end

      # Crea una nueva conexión utilizando la configuración global de la gema.
      # Delega la creación al factory principal.
      #
      # @see BugBunny.create_connection
      # @return [Bunny::Session] Una nueva sesión iniciada.
      def create_connection
        BugBunny.create_connection
      end

      # Cierra la conexión global de forma segura.
      #
      # Es un método idempotente: verifica si la conexión existe y está abierta antes de intentar cerrarla.
      # Utilizado comúnmente en los hooks de `at_exit`, o por Railties al recargar código en Spring/Puma.
      #
      # @return [void]
      def disconnect
        return unless @connection

        @connection.close if @connection.open?
        @connection = nil
        BugBunny.configuration.logger.info('[BugBunny] Global connection closed.')
      end

      # Helper de conveniencia para instanciar y ejecutar un Consumidor (Worker).
      #
      # Simplifica el arranque de workers desde tareas Rake, encapsulando la creación
      # de la instancia {BugBunny::Consumer} y la suscripción.
      #
      # @param connection [Bunny::Session] Conexión dedicada para el consumidor.
      # @param exchange [String] Nombre del exchange.
      # @param queue_name [String] Nombre de la cola.
      # @param routing_key [String] Routing key para el binding.
      # @param options [Hash] Opciones adicionales de topología.
      # @option options [String] :exchange_type ('direct') Tipo de exchange.
      # @option options [Hash] :queue_opts ({}) Opciones de la cola (:durable, etc).
      # @return [void] Este método suele bloquear la ejecución.
      def run_consumer(connection:, exchange:, queue_name:, routing_key:, **options)
        # 1. Instanciamos el Consumidor (que crea su propia Session interna)
        consumer = BugBunny::Consumer.new(connection)

        # 2. Iniciamos la suscripción delegando las opciones
        consumer.subscribe(
          queue_name: queue_name,
          exchange_name: exchange,
          routing_key: routing_key,
          **options
        )
      end
    end
  end
end
