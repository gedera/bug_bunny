# lib/bug_bunny/client.rb
require_relative 'middleware/stack'

module BugBunny
  class Client
    attr_reader :pool, :stack

    # @param pool [ConnectionPool] El pool de conexiones RabbitMQ.
    def initialize(pool:)
      raise ArgumentError, "BugBunny::Client requiere un 'pool:'" if pool.nil?
      @pool = pool

      # 1. Inicializamos el Stack vacío
      @stack = BugBunny::Middleware::Stack.new

      # 2. Permitimos configurar el stack en el bloque (Estilo Faraday)
      yield(@stack) if block_given?
    end

    # Método síncrono
    def request(url, **args)
      run_in_pool(:rpc, url, args) do |req|
        yield req if block_given?
      end
    end

    # Método asíncrono
    def publish(url, **args)
      run_in_pool(:fire, url, args) do |req|
        yield req if block_given?
      end
    end

    private

    def run_in_pool(method_name, url, args)
      # Builder del Request
      req = BugBunny::Request.new(url)

      # Syntactic Sugar
      req.body        = args[:body]        if args[:body]
      req.exchange    = args[:exchange]    if args[:exchange]
      req.exchange_type = args[:exchange_type] if args[:exchange_type]
      req.routing_key = args[:routing_key] if args[:routing_key]
      req.timeout     = args[:timeout]     if args[:timeout]
      req.headers.merge!(args[:headers])   if args[:headers]

      # Configuración del usuario (request específico)
      yield req if block_given?

      @pool.with do |conn|
        session = BugBunny::Session.new(conn)
        producer = BugBunny::Producer.new(session)

        begin
          # === AQUÍ ESTÁ LA MAGIA DEL MIDDLEWARE ===
          # 1. Definimos la "Acción Final" (El centro de la cebolla)
          # Esto es lo que se ejecuta si todos los middlewares llaman a 'call'
          final_action = ->(env) { producer.send(method_name, env) }

          # 2. Construimos la cadena para esta petición específica
          # El 'app' resultante es el primer middleware de la lista
          app = @stack.build(final_action)

          # 3. Ejecutamos la cadena pasando el request
          app.call(req)
        ensure
          session.close
        end
      end
    end
  end
end
