module BugBunny
  class Request
    # === DATOS (Payload) ===
    attr_accessor :body
    attr_accessor :headers

    # === ENRUTAMIENTO ===
    attr_accessor :action       # URL/Path (ej: 'users/create')
    attr_accessor :exchange     # Exchange destino
    attr_accessor :exchange_type # 'direct', 'topic', 'fanout'
    attr_accessor :routing_key  # Routing key manual

    # === CONFIGURACIÓN ===
    attr_accessor :timeout      # Segundos a esperar respuesta (Solo RPC)

    # === METADATOS AMQP ===
    attr_accessor :app_id
    attr_accessor :content_type
    attr_accessor :content_encoding
    attr_accessor :priority
    attr_accessor :timestamp
    attr_accessor :expiration   # TTL en ms
    attr_accessor :persistent
    attr_accessor :reply_to
    attr_accessor :correlation_id
    attr_accessor :type         # Override manual del header type

    def initialize(action)
      @action = action
      @headers = {}
      @content_type = 'application/json'
      @timestamp = Time.now.to_i
      @persistent = false
      @exchange_type = 'direct' # Default sensato
    end

    # Si no se define routing_key explícito, usa la action.
    def final_routing_key
      routing_key || action
    end

    # El valor que viaja en el header 'type'.
    def final_type
      type || action
    end

    # Hash limpio para Bunny
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
