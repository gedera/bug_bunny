# frozen_string_literal: true

require 'concurrent'

module BugBunny
  # Clase interna que encapsula una unidad de trabajo sobre una conexión RabbitMQ.
  #
  # Implementa la lógica de "Configuración en Cascada" para Exchanges y Colas,
  # gestionando el ciclo de vida de un `Bunny::Channel` con resiliencia y carga perezosa.
  #
  # @api private
  class Session
    include BugBunny::Observability

    # @!group Opciones por Defecto (Nivel 1: Gema)

    # Opciones predeterminadas de la gema para Exchanges.
    DEFAULT_EXCHANGE_OPTIONS = { durable: false, auto_delete: false }.freeze

    # Opciones predeterminadas de la gema para Colas.
    #
    # `durable: true, exclusive: false, auto_delete: false` es el patrón "queue compartida
    # duradera" — sobrevive restart del broker, múltiples consumers (worker pool) pueden
    # consumir, no se elimina cuando el último consumer se desconecta.
    #
    # Histórico: hasta 4.15.x el default era `{ exclusive: false, durable: false,
    # auto_delete: true }` (combo `transient_nonexcl_queues` deprecada en RabbitMQ 4.x).
    # Ver issue #42 para detalles de la migración. Para restaurar el comportamiento
    # anterior, configurar explícitamente:
    #
    #   BugBunny.configure do |c|
    #     c.queue_options = { exclusive: false, durable: false, auto_delete: true }
    #   end
    DEFAULT_QUEUE_OPTIONS = { exclusive: false, durable: true, auto_delete: false }.freeze

    # @!endgroup

    # @return [Bunny::Session] La conexión TCP subyacente.
    attr_reader :connection

    # Inicializa una nueva sesión sin abrir canales todavía.
    #
    # @param connection [Bunny::Session] Una conexión (puede estar abierta o cerrada temporalmente).
    # @param publisher_confirms [Boolean] Si es `true`, el canal se abre en modo Publisher Confirms.
    #   Activar solo en sesiones de Producer. En sesiones de Consumer genera overhead innecesario
    #   ya que los replies RPC son fire-and-forget desde la perspectiva del servidor.
    def initialize(connection, publisher_confirms: true)
      @connection = connection
      @publisher_confirms = publisher_confirms
      @channel = nil
      @channel_mutex = Mutex.new
      @logger = BugBunny.configuration.logger
      @configured_returns = {}
      @pending_returns = Concurrent::Map.new
    end

    # Registra interés en una eventual señal `basic.return` correlacionada con `cid`.
    #
    # Devuelve un par `(event, slot)`. El caller espera el `event` tras `wait_for_confirms`;
    # si el broker retorna el mensaje, {#handle_broker_return} setea el event y deposita
    # la `return_info` en `slot[:info]` antes de invocar el callback global del usuario.
    #
    # El caller es responsable de invocar {#unregister_return_listener} en un `ensure`
    # para evitar fugas en el registry interno.
    #
    # @param cid [String] Correlation ID del request en curso.
    # @return [Array(Concurrent::Event, Hash)] Tupla `[event, slot]`. `slot[:info]` será
    #   poblado con la `Bunny::ReturnInfo` si el broker retorna el mensaje.
    # @api private
    def register_return_listener(cid)
      slot = { event: Concurrent::Event.new, info: nil }
      @pending_returns[cid.to_s] = slot
      [slot[:event], slot]
    end

    # Elimina el listener registrado por {#register_return_listener}.
    #
    # @param cid [String]
    # @return [void]
    # @api private
    def unregister_return_listener(cid)
      @pending_returns.delete(cid.to_s)
    end

    # Obtiene el canal actual o crea uno nuevo si es necesario.
    #
    # Este método es el punto central de la robustez. Verifica la salud
    # de la conexión y del canal antes de devolverlo.
    #
    # @return [Bunny::Channel] Un canal abierto y configurado.
    # @raise [BugBunny::CommunicationError] Si no se puede restablecer la conexión.
    def channel
      # Fast path: canal abierto, sin adquirir el mutex.
      return @channel if @channel&.open?

      # Slow path: adquirimos el mutex y verificamos de nuevo (double-checked locking).
      # Evita que múltiples threads creen canales simultáneamente cuando el canal cae.
      @channel_mutex.synchronize do
        return @channel if @channel&.open?

        ensure_connection!
        create_channel!
      end

      @channel
    end

    # Factory method para declarar o recuperar un Exchange aplicando la cascada de configuración.
    #
    # Jerarquía de fusión:
    # 1. Defaults de la gema (`DEFAULT_EXCHANGE_OPTIONS`)
    # 2. Configuración global (`BugBunny.configuration.exchange_options`)
    # 3. Opciones específicas pasadas como argumento (`opts`)
    #
    # @param name [String, nil] Nombre del exchange.
    # @param type [String, Symbol] Tipo de exchange ('direct', 'topic', 'fanout').
    # @param opts [Hash] Opciones específicas de infraestructura para este intercambio.
    # @return [Bunny::Exchange] El objeto exchange de Bunny configurado.
    def exchange(name: nil, type: 'direct', opts: {})
      return channel.default_exchange if name.nil? || name.empty?

      # Aplicación de la lógica de fusión en cascada
      merged_opts = DEFAULT_EXCHANGE_OPTIONS
                    .merge(BugBunny.configuration.exchange_options || {})
                    .merge(opts)

      # public_send permite llamar a :topic, :direct, etc. dinámicamente según el tipo
      x = channel.public_send(type.to_s, name.to_s, merged_opts)
      register_on_return!(x) if @publisher_confirms
      x
    end

    # Factory method para declarar o recuperar una Cola aplicando la cascada de configuración.
    #
    # Jerarquía de fusión:
    # 1. Defaults de la gema (`DEFAULT_QUEUE_OPTIONS`)
    # 2. Configuración global (`BugBunny.configuration.queue_options`)
    # 3. Opciones específicas pasadas como argumento (`opts`)
    #
    # @param name [String] Nombre de la cola.
    # @param opts [Hash] Opciones específicas de infraestructura para esta cola.
    # @return [Bunny::Queue] El objeto cola de Bunny configurado.
    def queue(name, opts = {})
      # Aplicación de la lógica de fusión en cascada
      merged_opts = DEFAULT_QUEUE_OPTIONS
                    .merge(BugBunny.configuration.queue_options || {})
                    .merge(opts)

      channel.queue(name.to_s, merged_opts)
    end

    # Cierra el canal asociado a esta sesión de forma segura.
    # @return [void]
    def close
      @channel_mutex.synchronize do
        @channel&.close if @channel&.open?
        @channel = nil
        @configured_returns.clear
        release_pending_returns!
      end
    end

    private

    # Crea y configura un nuevo canal con las preferencias globales.
    # Asume que la conexión ya ha sido verificada por `ensure_connection!`.
    #
    # @raise [BugBunny::CommunicationError] Si falla la creación del canal.
    def create_channel!
      @channel = @connection.create_channel
      @configured_returns.clear

      @channel.confirm_select if @publisher_confirms

      @channel.prefetch(BugBunny.configuration.channel_prefetch) if BugBunny.configuration.channel_prefetch
    rescue StandardError => e
      raise BugBunny::CommunicationError, "Failed to create channel: #{e.message}"
    end

    # Libera todos los listeners pendientes seteando sus events. Permite que los publish
    # threads bloqueados en `event.wait` despierten cuando la sesión se cierra (shutdown),
    # en lugar de esperar a `confirm_timeout`. Solo se invoca desde {#close} — el cleanup
    # per-publish corre via `ensure` en {Producer#confirmed} → {#unregister_return_listener}.
    #
    # @return [void]
    def release_pending_returns!
      @pending_returns.each_pair do |_cid, slot|
        slot[:event].set
      end
      @pending_returns.clear
    end

    # Registra el handler `basic.return` sobre el `Bunny::Exchange` indicado.
    #
    # Bunny dispatcha `basic.return` por exchange (no por canal): el callback se setea
    # con `Exchange#on_return`. Como cada `Session#exchange` resuelve la misma instancia
    # cacheada en el canal, registramos una sola vez por nombre.
    #
    # - Si `BugBunny.configuration.on_return` está definido, lo invoca.
    # - Sino, logea el retorno como `session.broker_return` con nivel `:warn`.
    #
    # @param exchange [Bunny::Exchange] Exchange recién resuelto vía cascada.
    # @return [void]
    def register_on_return!(exchange)
      key = exchange.name.to_s
      return if key.empty? || @configured_returns[key]

      exchange.on_return do |return_info, properties, body|
        handle_broker_return(return_info, properties, body)
      end
      @configured_returns[key] = true
    end

    # Procesa un evento `basic.return` del broker. Nunca propaga excepciones del callback
    # de usuario para no romper el hilo de I/O de Bunny.
    #
    # Orden de operaciones:
    # 1. Si hay un listener registrado con el `correlation_id` del mensaje retornado,
    #    se deposita la `return_info` en su slot y se setea el event. Esto se hace
    #    *antes* del callback de usuario para que una excepción del user_cb no impida
    #    que el publish thread despierte y raisee `PublishUnroutable`.
    # 2. Se invoca el callback global `configuration.on_return` (o se logea si no hay).
    #
    # @param return_info [Bunny::ReturnInfo]
    # @param properties [Bunny::MessageProperties]
    # @param body [String]
    # @return [void]
    def handle_broker_return(return_info, properties, body)
      signal_return_listener(properties, return_info)
      dispatch_return_callback(return_info, properties, body)
    rescue StandardError => e
      safe_log(:error, 'session.on_return_failed', **exception_metadata(e))
    end

    # Deposita la info del return en el slot asociado al `correlation_id` del mensaje
    # retornado y setea el event para despertar al publish thread.
    #
    # @param properties [Bunny::MessageProperties]
    # @param return_info [Bunny::ReturnInfo]
    # @return [void]
    def signal_return_listener(properties, return_info)
      cid = properties.respond_to?(:correlation_id) ? properties.correlation_id : nil
      return if cid.nil?

      slot = @pending_returns[cid.to_s]
      return unless slot

      slot[:info] = return_info
      slot[:event].set
    end

    # Invoca el callback global `on_return` o logea el evento si no hay callback.
    # Las excepciones del user_cb se capturan en el rescue de {#handle_broker_return}
    # — el event interno ya fue seteado antes de llegar acá.
    #
    # @param return_info [Bunny::ReturnInfo]
    # @param properties [Bunny::MessageProperties]
    # @param body [String]
    # @return [void]
    def dispatch_return_callback(return_info, properties, body)
      user_cb = BugBunny.configuration.on_return
      if user_cb
        user_cb.call(return_info, properties, body)
      else
        safe_log(:warn, 'session.broker_return',
                 reply_code: return_info.reply_code,
                 reply_text: return_info.reply_text,
                 exchange: return_info.exchange,
                 routing_key: return_info.routing_key,
                 body_size: body.respond_to?(:bytesize) ? body.bytesize : nil)
      end
    end

    # Garantiza que la conexión TCP esté abierta.
    # Si está cerrada, intenta reconectarla (Reconexión Transparente).
    #
    # @raise [BugBunny::CommunicationError] Si falla la reconexión.
    def ensure_connection!
      return if @connection.open?

      safe_log(:warn, 'session.reconnect_attempt')
      @connection.start
    rescue StandardError => e
      safe_log(:error, 'session.reconnect_failed', **exception_metadata(e))
      raise BugBunny::CommunicationError, "Could not reconnect to RabbitMQ: #{e.message}"
    end
  end
end
