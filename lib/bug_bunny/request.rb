# frozen_string_literal: true

require 'rack/utils'

module BugBunny
  # Encapsula toda la información necesaria para realizar una petición o publicación.
  #
  # Actúa como el objeto "Environment" en la arquitectura de middlewares.
  # Contiene el cuerpo del mensaje, la configuración de enrutamiento, el **Verbo HTTP**
  # y las opciones de infraestructura específicas para la petición.
  #
  # @attr body [Object] El cuerpo del mensaje (Hash, Array o String).
  # @attr headers [Hash] Cabeceras personalizadas (Headers AMQP).
  # @attr params [Hash] Parámetros de query string (ej: { q: { foo: :bar } }).
  # @attr path [String] La ruta lógica del recurso (ej: 'users', 'users/123').
  # @attr method [Symbol, String] El verbo HTTP (:get, :post, :put, :delete). Default: :get.
  # @attr exchange [String] El nombre del Exchange destino.
  # @attr exchange_type [String] El tipo de exchange ('direct', 'topic', 'fanout').
  # @attr routing_key [String] La routing key específica. Si es nil, se usará {#path}.
  # @attr timeout [Integer] Tiempo máximo en segundos para timeout RPC.
  #
  # @attr delivery_mode [Symbol] El modo de entrega (:rpc o :publish).
  # @attr exchange_options [Hash] Opciones específicas para la declaración del Exchange en esta petición.
  # @attr queue_options [Hash] Opciones específicas para la declaración de la Cola en esta petición.
  class Request
    attr_accessor :body, :headers, :params, :path, :method, :exchange, :exchange_type, :routing_key, :timeout,
                  :delivery_mode, :queue_options

    # Configuración de Infraestructura Específica
    attr_accessor :exchange_options

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
      @params = {}
      @content_type = 'application/json'
      @timestamp = Time.now.to_i
      @persistent = false
      @exchange_type = 'direct'
      @delivery_mode = :rpc

      # Inicialización de opciones de infraestructura para evitar errores de nil durante el merge.
      @exchange_options = {}
      @queue_options = {}
    end

    # Combina el path con los params como query string.
    #
    # @return [String] El path completo con query string si hay params, o solo el path.
    def full_path
      return path if params.nil? || params.empty?

      "#{path}?#{Rack::Utils.build_nested_query(params)}"
    end

    # Calcula la Routing Key final que se usará en RabbitMQ.
    #
    # Principio: "Convention over Configuration".
    # Si no se define una `routing_key` manual, se asume que el `path` actúa como tal.
    # Los params NO afectan la routing key — son metadata de la petición, no del enrutamiento del exchange.
    #
    # @return [String] La routing key definitiva.
    def final_routing_key
      routing_key || path
    end

    # Calcula el valor para el header AMQP 'type'.
    # En esta arquitectura REST, el 'type' es la URL completa del recurso (path + query string).
    #
    # @return [String] El tipo de mensaje definitivo.
    def final_type
      type || full_path
    end

    # Genera el Hash de opciones limpio para la gema Bunny.
    #
    # **Importante:** Inyecta el verbo HTTP en los headers bajo la clave `x-http-method`.
    # Esto permite al Consumer enrutar correctamente a la acción del controlador.
    #
    # También inyecta los campos de OTel semantic conventions for messaging
    # (ver {BugBunny::OTel}) con `operation=publish`. Los headers del usuario
    # pueden sobrescribir los valores OTel (escape hatch); `x-http-method`
    # nunca se pisa porque es lo último en el merge.
    #
    # @return [Hash] Opciones listas para pasar a `exchange.publish`.
    def amqp_options
      otel_headers = BugBunny::OTel.messaging_headers(
        operation: 'publish',
        destination: exchange,
        routing_key: final_routing_key,
        message_id: correlation_id
      )
      # Orden del merge: OTel base -> headers del usuario -> x-http-method (inmutable)
      # OTel keys son symbols internamente; los stringificamos para Bunny AMQP headers.
      final_headers = otel_headers.transform_keys(&:to_s).merge(headers).merge('x-http-method' => method.to_s.upcase)

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
