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
  #
  # @example Publicación con Publisher Confirms sincrónicos
  #   client.publish('acct.start', exchange: 'acct_x', body: payload,
  #                  confirmed: true, mandatory: true, confirm_timeout: 0.5)
  class Client
    # @return [ConnectionPool] El pool de conexiones subyacente a RabbitMQ.
    attr_reader :pool

    # @return [BugBunny::Middleware::Stack] La pila de middlewares configurada.
    attr_reader :stack

    # @return [Symbol] El modo de entrega por defecto para este cliente (:rpc, :publish o :confirmed).
    attr_accessor :delivery_mode

    # Argumentos del cliente que se mapean 1:1 a setters del Request.
    REQUEST_ATTRS = %i[
      delivery_mode method body exchange exchange_type routing_key
      timeout exchange_options queue_options params
    ].freeze

    # Inicializa un nuevo cliente.
    #
    # @param pool [ConnectionPool] Pool de conexiones a RabbitMQ configurado previamente.
    # @yield [stack] Bloque opcional para configurar la pila de middlewares.
    # @raise [ArgumentError] Si no se proporciona un `pool`.
    def initialize(pool:)
      raise ArgumentError, "BugBunny::Client requiere un 'pool:'" if pool.nil?

      @pool = pool
      @stack = BugBunny::Middleware::Stack.new
      @delivery_mode = :rpc
      yield(@stack) if block_given?
    end

    # Realiza una petición general al estilo Faraday.
    # El comportamiento (RPC o Fire-and-forget) depende de {#delivery_mode}.
    #
    # @param url [String] La ruta del recurso.
    # @param args [Hash] Opciones de configuración.
    # @yield [req] Bloque para configurar el objeto Request directamente.
    def send(url, **args)
      run_in_pool(url, args) do |req|
        yield req if block_given?
      end
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
      send(url, **args) do |req|
        req.delivery_mode = :rpc
        yield req if block_given?
      end
    end

    # Realiza una publicación Fire-and-Forget. Por default es asíncrono (no espera confirmación).
    #
    # Pasando `confirmed: true` activa Publisher Confirms síncronos: el método bloquea hasta
    # que el broker confirme la recepción del mensaje. Útil para eventos críticos (auditoría,
    # billing) donde se requiere garantía de entrega sin el overhead de un RPC completo.
    #
    # @param url [String] La ruta del evento/recurso.
    # @param args [Hash] Mismas opciones que {#request}, excepto `:timeout`. Adicionales:
    # @option args [Boolean] :confirmed Si `true`, espera `wait_for_confirms` del broker.
    # @option args [Boolean] :mandatory Si `true`, el broker retorna el mensaje si no es ruteable.
    #   Para procesar retornos, configurar {BugBunny.configuration.on_return}.
    # @option args [Float] :confirm_timeout Segundos a esperar el confirm. `nil` espera indefinidamente.
    # @option args [Boolean] :nack_raise Override per-request del flag
    #   `BugBunny.configuration.nack_raise`. Si `nil` (default), se usa la configuración global.
    # @option args [Boolean] :return_raise Override per-request del flag
    #   `BugBunny.configuration.return_raise`. Si `nil` (default), se usa la configuración global.
    #   Requiere `mandatory: true` y `confirmed: true` para tener efecto — sino se emite un
    #   warning y el flag se ignora.
    # @yield [req] Bloque para configurar el objeto Request.
    # @return [Hash] `{ 'status' => 202, 'body' => nil }`.
    # @raise [BugBunny::RequestTimeout] Si `confirmed: true` y el broker no confirma a tiempo.
    # @raise [BugBunny::PublishNacked] Si `confirmed: true`, el broker NACKea, y `nack_raise` resuelto es true.
    # @raise [BugBunny::PublishUnroutable] Si `confirmed: true`, `mandatory: true`, el broker retorna el
    #   mensaje como no-ruteable, y `return_raise` resuelto es true.
    def publish(url, **args)
      send(url, **args) do |req|
        req.delivery_mode = args[:confirmed] ? :confirmed : :publish
        yield req if block_given?
      end
    end

    private

    # Ejecuta la lógica de envío dentro del contexto del Pool.
    # Mapea los argumentos al objeto Request y ejecuta la cadena de middlewares.
    #
    # @param url [String] La ruta destino.
    # @param args [Hash] Argumentos pasados a los métodos públicos.
    # @yield [req] Bloque para configuración adicional del Request.
    def run_in_pool(url, args)
      req = build_request(url, args)

      # Configuración del usuario (bloque específico por request)
      yield req if block_given?

      # Check post-block: el block API puede setear delivery_mode/mandatory después
      # de los keyword args. Evaluamos el warning sobre el estado final del Request.
      warn_return_raise_misuse(req)

      # Ejecución dentro del Pool.
      # Session y Producer se reutilizan por slot de conexión (ver #session_for / #producer_for).
      @pool.with do |conn|
        session  = session_for(conn)
        producer = producer_for(conn, session)

        # Onion Architecture: La acción final es llamar al Producer real.
        final_action = ->(env) { producer.send(producer_method_for(req.delivery_mode), env) }

        @stack.build(final_action).call(req)
      end
    end

    # Construye y completa un Request a partir de los argumentos del usuario.
    #
    # @param url [String] La ruta destino.
    # @param args [Hash] Argumentos pasados a los métodos públicos.
    # @return [BugBunny::Request] Request listo para entrar al stack de middlewares.
    def build_request(url, args)
      req = BugBunny::Request.new(url)
      req.delivery_mode = delivery_mode # Default del cliente
      apply_args(req, args)
      apply_publisher_confirms_args(req, args)
      req
    end

    # Mapea los argumentos generales (no específicos de Publisher Confirms) sobre el Request.
    #
    # @param req [BugBunny::Request]
    # @param args [Hash]
    # @return [void]
    def apply_args(req, args)
      REQUEST_ATTRS.each do |key|
        req.public_send("#{key}=", args[key]) if args[key]
      end
      req.headers.merge!(args[:headers]) if args[:headers]
    end

    # Mapea un delivery_mode al nombre del método correspondiente en el Producer.
    #
    # @param mode [Symbol] :rpc, :publish o :confirmed.
    # @return [Symbol] :rpc, :fire o :confirmed.
    def producer_method_for(mode)
      case mode
      when :publish   then :fire
      when :confirmed then :confirmed
      else :rpc
      end
    end

    # Aplica los argumentos específicos del modo :confirmed sobre el Request.
    #
    # @param req [BugBunny::Request]
    # @param args [Hash] Argumentos originales pasados al cliente.
    # @return [void]
    def apply_publisher_confirms_args(req, args)
      req.mandatory       = args[:mandatory]       if args.key?(:mandatory)
      req.confirm_timeout = args[:confirm_timeout] if args.key?(:confirm_timeout)
      req.nack_raise      = args[:nack_raise]      if args.key?(:nack_raise)
      req.return_raise    = args[:return_raise]    if args.key?(:return_raise)
    end

    # Emite un warning si el Request final tiene `return_raise: true` pero le falta
    # `delivery_mode == :confirmed` o `mandatory: true`. El flag requiere ambos para
    # tener efecto: sin confirmed no hay synchronization point sobre el cual levantar,
    # y sin mandatory el broker nunca retorna.
    #
    # Se evalúa sobre el Request post-block (no sobre args) para no producir falsos
    # positivos cuando el caller usa el block API para setear `req.delivery_mode` o
    # `req.mandatory` después de los keyword args.
    #
    # Solo warnea cuando `request.return_raise` fue explícitamente `true` por request —
    # ignora el default global (que también puede ser `true`) para no inundar logs en
    # publishes regulares sin mandatory.
    #
    # @param request [BugBunny::Request]
    # @return [void]
    def warn_return_raise_misuse(request)
      return unless request.return_raise == true
      return if request.delivery_mode == :confirmed && request.mandatory

      BugBunny.configuration.logger&.warn do
        'component=bug_bunny event=client.return_raise_ignored ' \
          'reason=requires_confirmed_and_mandatory ' \
          "delivery_mode=#{request.delivery_mode} mandatory=#{!!request.mandatory}"
      end
    end

    # Recupera o crea la Session asociada al slot de conexión dado.
    #
    # La Session (y su canal AMQP) se almacena como ivar en el objeto `conn`.
    # Thread-safe sin mutex adicional: ConnectionPool garantiza que cada `conn`
    # es usado por un único thread a la vez.
    #
    # @param conn [Bunny::Session] Conexión activa del pool.
    # @return [BugBunny::Session]
    def session_for(conn)
      conn.instance_variable_get(:@_bug_bunny_session) ||
        conn.instance_variable_set(:@_bug_bunny_session, BugBunny::Session.new(conn))
    end

    # Recupera o crea el Producer asociado al slot de conexión dado.
    #
    # El Producer debe cachearse junto con la Session porque registra un
    # `basic_consume` sobre el canal para escuchar replies RPC. Si se creara
    # un Producer nuevo por request (con el canal reutilizado), se intentaría
    # registrar un segundo consumidor sobre el mismo canal, causando un error AMQP.
    #
    # @param conn [Bunny::Session] Conexión activa del pool.
    # @param session [BugBunny::Session] Session ya resuelta para `conn`.
    # @return [BugBunny::Producer]
    def producer_for(conn, session)
      conn.instance_variable_get(:@_bug_bunny_producer) ||
        conn.instance_variable_set(:@_bug_bunny_producer, BugBunny::Producer.new(session))
    end
  end
end
