# frozen_string_literal: true

module BugBunny
  # Objeto Value (Value Object) que encapsula los datos de una petición saliente.
  #
  # Normaliza la información necesaria para que el {Producer} pueda enviar el mensaje
  # correctamente, ya sea en modo "Fire-and-Forget" o RPC.
  class Request
    # @return [String] URL o path del recurso (ej: 'users/123').
    attr_accessor :url

    # @return [Symbol] Verbo HTTP simulado (:get, :post, :put, :delete).
    attr_accessor :method

    # @return [Object] Cuerpo del mensaje (serializable a JSON).
    attr_accessor :body

    # @return [Hash] Headers AMQP adicionales.
    attr_accessor :headers

    # @return [String] Nombre del Exchange destino.
    attr_accessor :exchange

    # @return [String] Tipo de Exchange ('direct', 'topic', etc).
    attr_accessor :exchange_type

    # @return [String] Routing Key específica.
    attr_accessor :routing_key

    # @return [Integer, nil] Tiempo máximo de espera en segundos (para RPC).
    attr_accessor :timeout

    # @return [String, nil] Cola de respuesta (para RPC).
    attr_accessor :reply_to

    # @return [String, nil] ID de correlación único (para RPC).
    attr_accessor :correlation_id

    # Inicializa una nueva petición.
    # @param url [String] La ruta del recurso.
    def initialize(url)
      @url = url
      @method = :get
      @headers = {}
      @exchange = ''
      @exchange_type = 'direct'
      @routing_key = ''
      @timeout = nil
    end

    # Calcula la routing key final basándose en la configuración o la URL.
    #
    # Si no se especifica una routing key explícita, intenta inferirla de la URL
    # reemplazando barras por puntos (convención REST a AMQP).
    #
    # @return [String] La routing key definitiva.
    def final_routing_key
      return routing_key unless routing_key.nil? || routing_key.empty?

      # Convierte 'users/123/active' -> 'users.123.active'
      url.tr('/', '.')
    end

    # Separa el path de la query string si existe.
    # @return [String] El path limpio sin parámetros GET.
    def path
      url.split('?').first
    end

    # Genera las opciones formateadas para la librería Bunny.
    # Incluye headers de protocolo y metadatos RPC si son necesarios.
    #
    # @return [Hash] Opciones para `exchange.publish`.
    def amqp_options
      opts = {
        app_id: 'bug_bunny',
        type: url, # El "path" viaja en el header 'type' estándar de AMQP
        content_type: 'application/json',
        headers: headers.merge('x-http-method' => method.to_s.upcase)
      }

      add_rpc_options(opts)
      opts
    end

    private

    # Agrega opciones de respuesta solo si es una petición RPC.
    def add_rpc_options(opts)
      return unless reply_to

      opts[:reply_to] = reply_to
      opts[:correlation_id] = correlation_id
    end
  end
end
