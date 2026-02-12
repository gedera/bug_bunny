# lib/bug_bunny/consumer.rb
require 'active_support/core_ext/string/inflections'
require 'concurrent'
require 'json'
require 'uri'
require 'cgi'

module BugBunny
  # Consumidor de mensajes y Router RPC estilo REST.
  #
  # Esta clase se encarga de escuchar una cola específica, deserializar los mensajes,
  # interpretar los headers REST (`x-http-method`, `type`) y despacharlos al
  # controlador correspondiente.
  #
  # También gestiona el ciclo de vida de la respuesta RPC, asegurando que siempre
  # se envíe una contestación (éxito o error) para evitar timeouts en el cliente.
  class Consumer
    # @return [BugBunny::Session] La sesión de RabbitMQ wrapper.
    attr_reader :session

    # Método de conveniencia para instanciar y suscribir en un solo paso.
    # @param connection [Bunny::Session] Conexión activa.
    # @param args [Hash] Argumentos para {#subscribe}.
    def self.subscribe(connection:, **args)
      new(connection).subscribe(**args)
    end

    # Inicializa el consumidor.
    # @param connection [Bunny::Session] Conexión nativa de Bunny.
    def initialize(connection)
      @session = BugBunny::Session.new(connection)
    end

    # Inicia la suscripción a la cola y el procesamiento de mensajes.
    #
    # @param queue_name [String] Nombre de la cola a escuchar.
    # @param exchange_name [String] Exchange al que se bindeará la cola.
    # @param routing_key [String] Routing key para el binding.
    # @param exchange_type [String] Tipo de exchange ('direct', 'topic', etc).
    # @param queue_opts [Hash] Opciones de declaración de la cola (durable, auto_delete).
    # @param block [Boolean] Si es true, bloquea el hilo principal (loop).
    def subscribe(queue_name:, exchange_name:, routing_key:, exchange_type: 'direct', queue_opts: {}, block: true)
      x = session.exchange(name: exchange_name, type: exchange_type)
      q = session.queue(queue_name, queue_opts)
      q.bind(x, routing_key: routing_key)

      BugBunny.configuration.logger.info("[Consumer] Listening on #{queue_name} (Exchange: #{exchange_name})")
      start_health_check(queue_name)

      q.subscribe(manual_ack: true, block: block) do |delivery_info, properties, body|
        process_message(delivery_info, properties, body)
      end
    rescue StandardError => e
      BugBunny.configuration.logger.error("[Consumer] Connection Error: #{e.message}. Retrying...")
      sleep BugBunny.configuration.network_recovery_interval
      retry
    end

    private

    # Procesa un mensaje individual.
    #
    # 1. Parsea headers y body.
    # 2. Enruta al controlador/acción.
    # 3. Envía la respuesta RPC si es necesario.
    # 4. Maneja excepciones y envía errores formateados al cliente.
    #
    # @param delivery_info [Bunny::DeliveryInfo] Metadatos de entrega.
    # @param properties [Bunny::MessageProperties] Headers y propiedades AMQP.
    # @param body [String] Payload del mensaje.
    def process_message(delivery_info, properties, body)
      if properties.type.nil? || properties.type.empty?
        BugBunny.configuration.logger.error("[Consumer] Missing 'type'. Rejected.")
        session.channel.reject(delivery_info.delivery_tag, false)
        return
      end

      http_method = properties.headers ? (properties.headers['x-http-method'] || 'GET') : 'GET'

      # Inferencia de rutas (Router)
      route_info = router_dispatch(http_method, properties.type)

      headers = {
        type: properties.type,
        http_method: http_method,
        controller: route_info[:controller],
        action: route_info[:action],
        id: route_info[:id],
        query_params: route_info[:params],
        content_type: properties.content_type,
        correlation_id: properties.correlation_id,
        reply_to: properties.reply_to
      }

      # Instanciación dinámica del controlador
      # Ej: "users" -> Rabbit::Controllers::UsersController
      controller_class_name = "rabbit/controllers/#{route_info[:controller]}".camelize
      controller_class = controller_class_name.constantize

      # Ejecución del pipeline del controlador
      response_payload = controller_class.call(headers: headers, body: body)

      # Respuesta RPC (Éxito)
      if properties.reply_to
        reply(response_payload, properties.reply_to, properties.correlation_id)
      end

      session.channel.ack(delivery_info.delivery_tag)

    rescue NameError => e
      # Caso: Controlador o Acción no existen (404/501)
      BugBunny.configuration.logger.error("[Consumer] Routing Error: #{e.message}")

      # FIX CRÍTICO: Responder con error para evitar Timeout en el cliente
      if properties.reply_to
        error_payload = { status: 501, body: { error: "Routing Error", detail: e.message } }
        reply(error_payload, properties.reply_to, properties.correlation_id)
      end

      session.channel.reject(delivery_info.delivery_tag, false)

    rescue StandardError => e
      # Caso: Crash interno de la aplicación (500)
      BugBunny.configuration.logger.error("[Consumer] Execution Error: #{e.message}")

      # FIX CRÍTICO: Responder con 500 para evitar Timeout
      if properties.reply_to
        error_payload = { status: 500, body: { error: "Internal Server Error", detail: e.message } }
        reply(error_payload, properties.reply_to, properties.correlation_id)
      end

      session.channel.reject(delivery_info.delivery_tag, false)
    end

    # Simula el Router de Rails.
    # Convierte Verbo + Path en Controlador + Acción + ID.
    #
    # @return [Hash] { controller, action, id, params }
    def router_dispatch(method, path)
      uri = URI.parse("http://dummy/#{path}")
      segments = uri.path.split('/').reject(&:empty?)
      query_params = uri.query ? CGI.parse(uri.query).transform_values(&:first) : {}

      controller_name = segments[0]
      id = segments[1]

      action = case method.to_s.upcase
               when 'GET' then id ? 'show' : 'index'
               when 'POST' then 'create'
               when 'PUT', 'PATCH' then 'update'
               when 'DELETE' then 'destroy'
               else id || 'index'
               end

      # Soporte para Custom Member Actions (POST users/1/promote)
      if segments.size >= 3
         id = segments[1]
         action = segments[2]
      end

      query_params['id'] = id if id

      { controller: controller_name, action: action, id: id, params: query_params }
    end

    # Envía la respuesta a la cola temporal del cliente (Direct Reply-to).
    def reply(payload, reply_to, correlation_id)
      session.channel.default_exchange.publish(
        payload.to_json,
        routing_key: reply_to,
        correlation_id: correlation_id,
        content_type: 'application/json'
      )
    end

    # Tarea de fondo para asegurar que la cola sigue existiendo.
    def start_health_check(q_name)
      Concurrent::TimerTask.new(execution_interval: 60) do
        session.channel.queue_declare(q_name, passive: true)
      rescue StandardError
        session.close
      end.execute
    end
  end
end
