# lib/bug_bunny/client.rb
require_relative 'middleware/stack'

module BugBunny
  # Cliente principal para realizar peticiones a RabbitMQ con semántica REST.
  #
  # @example Petición GET
  #   client.get('users/123')
  #
  # @example Petición POST
  #   client.post('users', body: { name: 'Gaby' })
  class Client
    attr_reader :pool, :stack

    def initialize(pool:)
      raise ArgumentError, "BugBunny::Client requiere un 'pool:'" if pool.nil?
      @pool = pool
      @stack = BugBunny::Middleware::Stack.new
      yield(@stack) if block_given?
    end

    # --- VERBOS HTTP (Syntactic Sugar) ---

    # Realiza una petición GET (RPC). Ideal para lecturas (show, index).
    def get(url, **args)
      request(url, method: :get, **args)
    end

    # Realiza una petición POST (RPC). Ideal para creaciones (create).
    def post(url, **args)
      request(url, method: :post, **args)
    end

    # Realiza una petición PUT (RPC). Ideal para actualizaciones completas (update).
    def put(url, **args)
      request(url, method: :put, **args)
    end

    # Realiza una petición DELETE (RPC). Ideal para eliminaciones (destroy).
    def delete(url, **args)
      request(url, method: :delete, **args)
    end

    # --- MÉTODOS CORE ---

    # Realiza una petición Síncrona (RPC).
    #
    # @param url [String] La ruta del recurso.
    # @param method [Symbol] El verbo HTTP (:get, :post, etc).
    # @param args [Hash] Opciones (body, headers, timeout).
    def request(url, method: :get, **args)
      run_in_pool(:rpc, url, args.merge(method: method)) do |req|
        yield req if block_given?
      end
    end

    # Realiza una publicación Asíncrona (Fire-and-Forget).
    # Por defecto usa POST si no se especifica método.
    def publish(url, method: :post, **args)
      run_in_pool(:fire, url, args.merge(method: method)) do |req|
        yield req if block_given?
      end
    end

    private

    def run_in_pool(method_name, url, args)
      # Pasamos el verbo al inicializador del Request
      req = BugBunny::Request.new(url, method: args[:method])

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
