# lib/bug_bunny/client.rb
require_relative 'middleware/stack'

module BugBunny
  # Cliente principal para realizar peticiones a RabbitMQ.
  # Implementa el patrón "Onion Middleware" similar a Faraday para interceptar
  # y procesar requests y responses.
  #
  # @example Inicialización básica
  #   client = BugBunny::Client.new(pool: MY_POOL)
  #
  # @example Con Middlewares
  #   client = BugBunny::Client.new(pool: MY_POOL) do |conn|
  #     conn.use BugBunny::Middleware::Logger, Rails.logger
  #   end
  class Client
    # @return [ConnectionPool] El pool de conexiones subyacente.
    attr_reader :pool
    # @return [BugBunny::Middleware::Stack] La pila de middlewares configurada.
    attr_reader :stack

    # Inicializa un nuevo cliente.
    #
    # @param pool [ConnectionPool] Pool de conexiones a RabbitMQ.
    # @yield [stack] Bloque opcional para configurar middlewares.
    # @yieldparam stack [BugBunny::Middleware::Stack] El stack de middlewares.
    def initialize(pool:)
      raise ArgumentError, "BugBunny::Client requiere un 'pool:'" if pool.nil?
      @pool = pool
      @stack = BugBunny::Middleware::Stack.new
      yield(@stack) if block_given?
    end

    # Realiza una petición Síncrona (RPC / Request-Response).
    # Bloquea la ejecución hasta recibir respuesta o superar el timeout.
    #
    # @param url [String] La ruta o acción del mensaje (ej: 'users/create').
    # @param args [Hash] Opciones de la petición.
    # @option args [Object] :body El cuerpo del mensaje (Hash o String).
    # @option args [String] :exchange Nombre del exchange destino.
    # @option args [String] :exchange_type Tipo de exchange ('direct', 'topic', etc).
    # @option args [String] :routing_key Routing key manual (opcional).
    # @option args [Integer] :timeout Tiempo máximo de espera en segundos.
    # @option args [Hash] :headers Headers AMQP adicionales.
    # @yield [req] Bloque para configurar el objeto Request.
    # @yieldparam req [BugBunny::Request] Objeto request configurable.
    # @return [Hash] La respuesta del servidor ({ 'status' => 200, 'body' => ... }).
    # @raise [BugBunny::RequestTimeout] Si no hay respuesta en el tiempo límite.
    def request(url, **args)
      run_in_pool(:rpc, url, args) do |req|
        yield req if block_given?
      end
    end

    # Realiza una publicación Asíncrona (Fire-and-Forget).
    # Envía el mensaje y retorna inmediatamente sin esperar respuesta.
    #
    # @param url [String] La ruta o acción del mensaje.
    # @param args [Hash] Mismas opciones que {#request}, excepto :timeout.
    # @yield [req] Bloque para configurar el objeto Request.
    # @return [void]
    def publish(url, **args)
      run_in_pool(:fire, url, args) do |req|
        yield req if block_given?
      end
    end

    private

    # Ejecuta la lógica dentro del contexto del Pool y aplica los middlewares.
    def run_in_pool(method_name, url, args)
      req = BugBunny::Request.new(url)

      # Syntactic Sugar
      req.body          = args[:body]          if args[:body]
      req.exchange      = args[:exchange]      if args[:exchange]
      req.exchange_type = args[:exchange_type] if args[:exchange_type]
      req.routing_key   = args[:routing_key]   if args[:routing_key]
      req.timeout       = args[:timeout]       if args[:timeout]
      req.headers.merge!(args[:headers])       if args[:headers]

      yield req if block_given?

      @pool.with do |conn|
        session = BugBunny::Session.new(conn)
        producer = BugBunny::Producer.new(session)

        begin
          # Onion Architecture: La acción final es el Producer real
          final_action = ->(env) { producer.send(method_name, env) }
          app = @stack.build(final_action)
          app.call(req)
        ensure
          session.close
        end
      end
    end
  end
end
