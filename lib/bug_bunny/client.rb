# frozen_string_literal: true

require_relative 'middleware/stack'

module BugBunny
  # Cliente principal para realizar peticiones a RabbitMQ.
  #
  # Implementa el patrón "Onion Middleware" (Arquitectura de Cebolla) similar a Faraday.
  # Mantiene una interfaz flexible donde el verbo HTTP se pasa como opción y permite
  # configurar la infraestructura AMQP de forma granular por petición.
  #
  # @example Petición RPC (GET) con opciones de infraestructura
  #   client.request('users/123', method: :get, exchange_options: { durable: true })
  #
  # @example Publicación Fire-and-Forget (POST)
  #   client.publish('logs', method: :post, body: { msg: 'Error' })
  class Client
    # @return [ConnectionPool] El pool de conexiones subyacente a RabbitMQ.
    attr_reader :pool

    # @return [BugBunny::Middleware::Stack] La pila de middlewares configurada.
    attr_reader :stack

    # Inicializa un nuevo cliente.
    #
    # @param pool [ConnectionPool] Pool de conexiones a RabbitMQ configurado previamente.
    # @yield [stack] Bloque opcional para configurar la pila de middlewares.
    # @raise [ArgumentError] Si no se proporciona un `pool`.
    def initialize(pool:)
      raise ArgumentError, "BugBunny::Client requiere un 'pool:'" if pool.nil?
      @pool = pool
      @stack = BugBunny::Middleware::Stack.new
      yield(@stack) if block_given?
    end

    # Realiza una petición Síncrona (RPC / Request-Response).
    #
    # Envía un mensaje y bloquea la ejecución del hilo actual hasta recibir respuesta.
    #
    # @param url [String] La ruta del recurso (ej: 'users/1').
    # @param args [Hash] Opciones de configuración.
    # @option args [Symbol] :method El verbo HTTP (:get, :post, :put, :delete). Default: :get.
    # @option args [Object] :body El cuerpo del mensaje.
    # @option args [Hash] :headers Headers AMQP adicionales.
    # @option args [Integer] :timeout Tiempo máximo de espera.
    # @option args [Hash] :exchange_options Opciones específicas para la declaración del Exchange.
    # @option args [Hash] :queue_options Opciones específicas para la declaración de la Cola.
    # @yield [req] Bloque para configurar el objeto Request directamente.
    # @return [Hash] La respuesta del servidor.
    def request(url, **args)
      run_in_pool(:rpc, url, args) do |req|
        yield req if block_given?
      end
    end

    # Realiza una publicación Asíncrona (Fire-and-Forget).
    #
    # @param url [String] La ruta del evento/recurso.
    # @param args [Hash] Mismas opciones que {#request}, excepto `:timeout`.
    # @yield [req] Bloque para configurar el objeto Request.
    # @return [void]
    def publish(url, **args)
      run_in_pool(:fire, url, args) do |req|
        yield req if block_given?
      end
    end

    private

    # Ejecuta la lógica de envío dentro del contexto del Pool.
    # Mapea los argumentos al objeto Request y ejecuta la cadena de middlewares.
    #
    # @param method_name [Symbol] El método del productor a llamar (:rpc o :fire).
    # @param url [String] La ruta destino.
    # @param args [Hash] Argumentos pasados a los métodos públicos.
    # @yield [req] Bloque para configuración adicional del Request.
    def run_in_pool(method_name, url, args)
      # 1. Builder del Request
      req = BugBunny::Request.new(url)

      # 2. Syntactic Sugar: Mapeo de argumentos a atributos del Request
      req.method           = args[:method]           if args[:method]
      req.body             = args[:body]             if args[:body]
      req.exchange         = args[:exchange]         if args[:exchange]
      req.exchange_type    = args[:exchange_type]    if args[:exchange_type]
      req.routing_key      = args[:routing_key]      if args[:routing_key]
      req.timeout          = args[:timeout]          if args[:timeout]

      # Inyección de opciones de infraestructura (Nivel 3 de la cascada)
      req.exchange_options = args[:exchange_options] if args[:exchange_options]
      req.queue_options    = args[:queue_options]    if args[:queue_options]

      req.headers.merge!(args[:headers])             if args[:headers]

      # 3. Configuración del usuario (bloque específico por request)
      yield req if block_given?

      # 4. Ejecución dentro del Pool
      @pool.with do |conn|
        session = BugBunny::Session.new(conn)
        producer = BugBunny::Producer.new(session)

        begin
          # Onion Architecture: La acción final es llamar al Producer real.
          final_action = ->(env) { producer.send(method_name, env) }

          # Construimos y ejecutamos la cadena de middlewares
          app = @stack.build(final_action)
          app.call(req)
        ensure
          # Aseguramos el cierre del canal pero mantenemos la conexión del pool
          session.close
        end
      end
    end
  end
end
