# lib/bug_bunny/request.rb

module BugBunny
  # Encapsula toda la información necesaria para realizar una petición o publicación.
  #
  # Actúa como el objeto "Environment" en la arquitectura de middlewares.
  # Contiene el cuerpo del mensaje, la configuración de enrutamiento y todos los
  # metadatos estándar del protocolo AMQP 0.9.1.
  class Request
    # === DATOS (Payload) ===

    # @return [Object] El cuerpo del mensaje (Hash, Array o String) antes de ser serializado.
    attr_accessor :body

    # @return [Hash] Cabeceras personalizadas (Headers AMQP) para pasar metadatos extra.
    attr_accessor :headers

    # === ENRUTAMIENTO ===

    # @return [String] La "ruta" lógica del mensaje (ej: 'users/create'). Se usa por defecto como routing key y type.
    attr_accessor :action

    # @return [String] El nombre del Exchange destino donde se publicará el mensaje.
    attr_accessor :exchange

    # @return [String] El tipo de exchange ('direct', 'topic', 'fanout', 'headers'). Default: 'direct'.
    attr_accessor :exchange_type

    # @return [String] La routing key específica para RabbitMQ. Si es nil, se usará {#action}.
    attr_accessor :routing_key

    # === CONFIGURACIÓN ===

    # @return [Integer] Tiempo máximo en segundos que el cliente RPC esperará la respuesta.
    attr_accessor :timeout

    # === METADATOS AMQP ===

    # @return [String] Identificador de la aplicación origen (App ID).
    attr_accessor :app_id

    # @return [String] Tipo MIME del contenido (Default: 'application/json').
    attr_accessor :content_type

    # @return [String] Codificación del contenido (ej: 'gzip').
    attr_accessor :content_encoding

    # @return [Integer] Prioridad del mensaje (0-9).
    attr_accessor :priority

    # @return [Integer] Timestamp UNIX del momento de creación.
    attr_accessor :timestamp

    # @return [String, Integer] Tiempo de vida (TTL) del mensaje en milisegundos.
    attr_accessor :expiration

    # @return [Boolean] Si es `true`, el mensaje se guardará en disco (más lento, más seguro). Default: `false`.
    attr_accessor :persistent

    # @return [String] Cola específica donde se espera la respuesta (usado internamente para RPC).
    attr_accessor :reply_to

    # @return [String] ID único para correlacionar petición y respuesta (RPC).
    attr_accessor :correlation_id

    # @return [String] Sobrescribe el header 'type' de AMQP. Vital para el enrutamiento en el Consumer.
    attr_accessor :type

    # Inicializa un nuevo Request.
    #
    # Establece valores por defecto sensatos:
    # * Content-Type: application/json
    # * Timestamp: Ahora
    # * Persistent: false (Modo rápido/volátil por defecto)
    # * Exchange Type: direct
    #
    # @param action [String] La acción o ruta lógica del mensaje (ej: 'users/update').
    def initialize(action)
      @action = action
      @headers = {}
      @content_type = 'application/json'
      @timestamp = Time.now.to_i
      @persistent = false
      @exchange_type = 'direct'
    end

    # Calcula la Routing Key final que se usará en RabbitMQ.
    #
    # Principio: "Convention over Configuration".
    # Si no se define una `routing_key` manual, se asume que la `action` actúa como tal.
    #
    # @return [String] La routing key definitiva.
    def final_routing_key
      routing_key || action
    end

    # Calcula el valor para el header AMQP 'type'.
    #
    # Este valor es utilizado por {BugBunny::Consumer} para decidir qué Controlador ejecutar.
    # Si no se define manualmente, usa la `action`.
    #
    # @return [String] El tipo de mensaje definitivo.
    def final_type
      type || action
    end

    # Genera el Hash de opciones limpio para la gema Bunny.
    #
    # Elimina las claves con valor `nil` (`compact`) para reducir el tamaño del paquete de red.
    #
    # @return [Hash] Opciones listas para pasar a `exchange.publish`.
    def amqp_options
      {
        type: final_type,
        app_id: app_id,
        content_type: content_type,
        content_encoding: content_encoding,
        priority: priority,
        timestamp: timestamp,
        expiration: expiration,
        persistent: persistent,
        headers: headers,
        reply_to: reply_to,
        correlation_id: correlation_id
      }.compact
    end
  end
end
