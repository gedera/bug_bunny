# lib/bug_bunny/client.rb
require_relative 'middleware/stack'

module BugBunny
  # Cliente principal para realizar peticiones a RabbitMQ.
  #
  # Implementa el patrón "Onion Middleware" (Arquitectura de Cebolla) similar a Faraday,
  # permitiendo interceptar, transformar y procesar tanto las peticiones salientes
  # como las respuestas entrantes mediante una pila de middlewares.
  #
  # @example Inicialización básica
  #   client = BugBunny::Client.new(pool: MY_POOL)
  #
  # @example Con Middlewares personalizados
  #   client = BugBunny::Client.new(pool: MY_POOL) do |conn|
  #     conn.use BugBunny::Middleware::RaiseError
  #     conn.use BugBunny::Middleware::JsonResponse
  #     conn.use BugBunny::Middleware::Logger, Rails.logger
  #   end
  class Client
    # @return [ConnectionPool] El pool de conexiones subyacente a RabbitMQ.
    attr_reader :pool

    # @return [BugBunny::Middleware::Stack] La pila de middlewares configurada para este cliente.
    attr_reader :stack

    # Inicializa un nuevo cliente.
    #
    # @param pool [ConnectionPool] Pool de conexiones a RabbitMQ configurado previamente.
    # @yield [stack] Bloque opcional para configurar la pila de middlewares.
    # @yieldparam stack [BugBunny::Middleware::Stack] El objeto stack para registrar middlewares con {#use}.
    # @raise [ArgumentError] Si no se proporciona un `pool`.
    def initialize(pool:)
      raise ArgumentError, "BugBunny::Client requiere un 'pool:'" if pool.nil?
      @pool = pool
      @stack = BugBunny::Middleware::Stack.new
      yield(@stack) if block_given?
    end

    # Realiza una petición Síncrona (RPC / Request-Response).
    #
    # Envía un mensaje y bloquea la ejecución del hilo actual hasta recibir una respuesta
    # correlacionada del servidor o hasta que se supere el tiempo de espera (timeout).
    #
    # @param url [String] La ruta o acción del mensaje (ej: 'users/create').
    # @param args [Hash] Opciones de configuración de la petición.
    # @option args [Object] :body El cuerpo del mensaje (Hash o String).
    # @option args [String] :exchange Nombre del exchange destino.
    # @option args [String] :exchange_type Tipo de exchange ('direct', 'topic', 'fanout').
    # @option args [String] :routing_key Routing key manual (opcional).
    # @option args [Integer] :timeout Tiempo máximo de espera en segundos antes de lanzar timeout.
    # @option args [Hash] :headers Headers AMQP adicionales para metadatos.
    # @yield [req] Bloque opcional para configurar el objeto Request directamente.
    # @yieldparam req [BugBunny::Request] Objeto request configurable.
    # @return [Hash] La respuesta del servidor, conteniendo habitualmente `status` y `body`.
    # @raise [BugBunny::RequestTimeout] Si no se recibe respuesta en el tiempo límite.
    def request(url, **args)
      run_in_pool(:rpc, url, args) do |req|
        yield req if block_given?
      end
    end

    # Realiza una publicación Asíncrona (Fire-and-Forget).
    #
    # Envía el mensaje al exchange y retorna el control inmediatamente sin esperar
    # ninguna confirmación o respuesta del consumidor.
    #
    # @param url [String] La ruta o acción del mensaje.
    # @param args [Hash] Mismas opciones que {#request}, excepto `:timeout` (no aplica).
    # @yield [req] Bloque opcional para configurar el objeto Request.
    # @yieldparam req [BugBunny::Request] Objeto request configurable.
    # @return [void]
    def publish(url, **args)
      run_in_pool(:fire, url, args) do |req|
        yield req if block_given?
      end
    end

    private

    # Ejecuta la lógica de envío dentro del contexto del Pool y aplica la cadena de middlewares.
    #
    # @param method_name [Symbol] El método a invocar en el Producer (:rpc o :fire).
    # @param url [String] La URL/Acción del request.
    # @param args [Hash] Argumentos pasados al método público.
    def run_in_pool(method_name, url, args)
      # 1. Builder del Request
      req = BugBunny::Request.new(url)

      # 2. Syntactic Sugar: Mapeo de argumentos a atributos del Request
      req.body          = args[:body]          if args[:body]
      req.exchange      = args[:exchange]      if args[:exchange]
      req.exchange_type = args[:exchange_type] if args[:exchange_type]
      req.routing_key   = args[:routing_key]   if args[:routing_key]
      req.timeout       = args[:timeout]       if args[:timeout]
      req.headers.merge!(args[:headers])       if args[:headers]

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
          session.close
        end
      end
    end
  end
end
