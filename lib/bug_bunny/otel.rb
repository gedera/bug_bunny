# frozen_string_literal: true

module BugBunny
  # Helpers para emitir campos siguiendo las OTel semantic conventions for messaging.
  # https://opentelemetry.io/docs/specs/otel/trace/semantic-conventions/messaging/
  #
  # Se usa tanto en el lado publisher (inyección en headers AMQP) como en el consumer
  # (enriquecimiento de log events estructurados). Centraliza las claves para evitar
  # strings mágicos dispersos y facilitar los tests.
  module OTel
    # Clave: sistema de mensajería. Siempre `"rabbitmq"` en BugBunny.
    # Flat-naming siguiendo el patrón de ExisRay (underscore sin dots).
    SYSTEM = :messaging_system
    # Clave: tipo de operación (`publish`, `receive`, `process`).
    OPERATION = :messaging_operation
    # Clave: nombre del exchange destino.
    DESTINATION = :messaging_destination_name
    # Clave: routing key del mensaje (específica de RabbitMQ).
    ROUTING_KEY = :messaging_routing_key
    # Clave: identificador único del mensaje. En BugBunny se mapea a `correlation_id`.
    MESSAGE_ID = :messaging_message_id

    # Valor constante para {SYSTEM}.
    SYSTEM_VALUE = 'rabbitmq'

    # Construye el hash de campos OTel para messaging.
    #
    # Los campos son aptos tanto para inyectar en headers AMQP como para mergear
    # en kwargs de log events estructurados.
    #
    # @param operation [String] Una de: `"publish"`, `"receive"`, `"process"`.
    # @param destination [String, nil] Nombre del exchange destino (puede ser `""` para default exchange).
    # @param routing_key [String, nil] Routing key final del mensaje.
    # @param message_id [String, nil] Identificador del mensaje. Se omite si es `nil`.
    # @return [Hash{String=>String}] Hash con los campos OTel de messaging.
    def self.messaging_headers(operation:, destination:, routing_key:, message_id: nil)
      fields = {
        SYSTEM => SYSTEM_VALUE,
        OPERATION => operation,
        DESTINATION => destination.to_s,
        ROUTING_KEY => routing_key.to_s
      }
      fields[MESSAGE_ID] = message_id.to_s if message_id
      fields
    end
  end
end
