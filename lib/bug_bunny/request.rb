# frozen_string_literal: true

# lib/bug_bunny/request.rb

module BugBunny
  # Encapsula toda la información necesaria para realizar una petición o publicación.
  #
  # Actúa como el objeto "Environment" en la arquitectura de middlewares.
  # Contiene el cuerpo del mensaje, la configuración de enrutamiento y el **Verbo HTTP**.
  #
  # @attr body [Object] El cuerpo del mensaje (Hash, Array o String).
  # @attr headers [Hash] Cabeceras personalizadas (Headers AMQP).
  # @attr path [String] La ruta lógica del recurso (ej: 'users', 'users/123').
  # @attr method [Symbol, String] El verbo HTTP (:get, :post, :put, :delete). Default: :get.
  # @attr exchange [String] El nombre del Exchange destino.
  # @attr exchange_type [String] El tipo de exchange ('direct', 'topic', 'fanout').
  # @attr routing_key [String] La routing key específica. Si es nil, se usará {#path}.
  # @attr timeout [Integer] Tiempo máximo en segundos para timeout RPC.
  class Request
    attr_accessor :body, :headers, :path, :method, :exchange, :exchange_type, :routing_key, :timeout

    # Metadatos AMQP Estándar
    attr_accessor :app_id, :content_type, :content_encoding, :priority,
                  :timestamp, :expiration, :persistent, :reply_to,
                  :correlation_id, :type

    # Inicializa un nuevo Request.
    #
    # @param path [String] La ruta del recurso o acción (ej: 'users/123').
    def initialize(path)
      @path = path
      @method = :get # Verbo por defecto
      @headers = {}
      @content_type = 'application/json'
      @timestamp = Time.now.to_i
      @persistent = false
      @exchange_type = 'direct'
    end

    # Calcula la Routing Key final que se usará en RabbitMQ.
    #
    # Principio: "Convention over Configuration".
    # Si no se define una `routing_key` manual, se asume que el `path` actúa como tal.
    #
    # @return [String] La routing key definitiva.
    def final_routing_key
      routing_key || path
    end

    # Calcula el valor para el header AMQP 'type'.
    # En esta arquitectura REST, el 'type' es la URL del recurso (el path).
    #
    # @return [String] El tipo de mensaje definitivo.
    def final_type
      type || path
    end

    # Genera el Hash de opciones limpio para la gema Bunny.
    #
    # **Importante:** Inyecta el verbo HTTP en los headers bajo la clave `x-http-method`.
    # Esto permite al Consumer enrutar correctamente a la acción del controlador.
    #
    # @return [Hash] Opciones listas para pasar a `exchange.publish`.
    def amqp_options
      # Inyectamos el verbo HTTP en los headers para el Router del Consumer
      final_headers = headers.merge('x-http-method' => method.to_s.upcase)

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
