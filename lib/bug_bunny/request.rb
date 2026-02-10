# lib/bug_bunny/request.rb

module BugBunny
  # Encapsula toda la información necesaria para realizar una petición o publicación.
  #
  # Actúa como el objeto "Environment" en la arquitectura de middlewares.
  # Contiene el cuerpo del mensaje, la configuración de enrutamiento, el VERBO HTTP
  # y todos los metadatos estándar del protocolo AMQP 0.9.1.
  class Request
    # === DATOS (Payload) ===

    # @return [Object] El cuerpo del mensaje (Hash, Array o String).
    attr_accessor :body

    # @return [Hash] Cabeceras personalizadas (Headers AMQP).
    attr_accessor :headers

    # === ENRUTAMIENTO REST ===

    # @return [String] La ruta lógica del recurso (ej: 'users', 'users/123').
    attr_accessor :path

    # @return [Symbol, String] El verbo HTTP (GET, POST, PUT, DELETE).
    attr_accessor :method

    # === INFRAESTRUCTURA AMQP ===

    # @return [String] El nombre del Exchange destino.
    attr_accessor :exchange

    # @return [String] El tipo de exchange ('direct', 'topic', 'fanout').
    attr_accessor :exchange_type

    # @return [String] La routing key específica. Si es nil, se usará {#path}.
    attr_accessor :routing_key

    # === CONFIGURACIÓN ===

    # @return [Integer] Tiempo máximo en segundos para timeout RPC.
    attr_accessor :timeout

    # === METADATOS AMQP ===

    # @return [String] App ID.
    attr_accessor :app_id
    # @return [String] Content Type (Default: application/json).
    attr_accessor :content_type
    # @return [String] Content Encoding.
    attr_accessor :content_encoding
    # @return [Integer] Prioridad (0-9).
    attr_accessor :priority
    # @return [Integer] Timestamp.
    attr_accessor :timestamp
    # @return [String] Expiration (TTL).
    attr_accessor :expiration
    # @return [Boolean] Persistent.
    attr_accessor :persistent
    # @return [String] Reply To queue.
    attr_accessor :reply_to
    # @return [String] Correlation ID.
    attr_accessor :correlation_id
    # @return [String] Type header override.
    attr_accessor :type

    # Inicializa un nuevo Request.
    #
    # @param path [String] La ruta del recurso (ej: 'users/123').
    # @param method [Symbol] El verbo HTTP (:get, :post, :put, :delete).
    def initialize(path, method: :get)
      @path = path
      @method = method.to_s.upcase
      @headers = {}
      @content_type = 'application/json'
      @timestamp = Time.now.to_i
      @persistent = false
      @exchange_type = 'direct'
    end

    # Calcula la Routing Key final.
    # Usa la ruta como key por defecto si no se especifica una manual.
    # @return [String]
    def final_routing_key
      routing_key || path
    end

    # Calcula el valor para el header AMQP 'type'.
    # En esta arquitectura REST, el 'type' es la URL del recurso (el path).
    # @return [String]
    def final_type
      type || path
    end

    # Genera el Hash de opciones para Bunny.
    #
    # INYECTA el verbo HTTP en los headers bajo la clave 'x-http-method'.
    # Esto permite al Consumer enrutar correctamente a la acción del controlador.
    #
    # @return [Hash] Opciones para exchange.publish.
    def amqp_options
      # Fusionamos el método HTTP en los headers
      final_headers = headers.merge('x-http-method' => method)

      {
        type: final_type,
        app_id: app_id,
        content_type: content_type,
        content_encoding: content_encoding,
        priority: priority,
        timestamp: timestamp,
        expiration: expiration,
        persistent: persistent,
        headers: final_headers,
        reply_to: reply_to,
        correlation_id: correlation_id
      }.compact
    end
  end
end
