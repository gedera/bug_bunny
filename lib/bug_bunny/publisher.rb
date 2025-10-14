# content_type:
# Propósito: Indica el formato de codificación del cuerpo del mensaje (ej. application/json, text/plain, application/xml).
# Uso Recomendado: dice a tu código qué lógica de deserialización aplicar. Si es application/json, usas JSON.parse.

# content_encoding:
# Propósito: Indica cómo se comprimió o codificó el cuerpo del mensaje (ej. gzip, utf-8).
# Uso Recomendado: Si envías cuerpos grandes, puedes comprimirlos (ej. con Gzip) para ahorrar ancho de banda y usar este campo para que el consumidor sepa cómo descomprimirlos antes de usar el content_type.

# correlation_id:
# Propósito: Un identificador único que se usa para correlacionar una respuesta con una petición previa.
# Uso Recomendado: Es indispensable en el patrón Remote Procedure Call (RPC). Si un productor envía una petición, copia este ID a la respuesta. Cuando el productor recibe la respuesta, usa este ID para saber a qué petición original corresponde.

# reply_to:
# Propósito: Especifica el nombre de la cola a la que el consumidor debe enviar la respuesta.
# Uso Recomendado: También clave en RPC. El productor especifica aquí su cola de respuesta temporal o exclusiva. El consumidor toma el mensaje, procesa, y publica el resultado en la cola indicada en reply_to.

# message_id:
# Propósito: Un identificador único para el mensaje en sí.
# Uso Recomendado: Ayuda a prevenir el procesamiento duplicado si un sistema de consumo cae y se recupera. El consumidor puede almacenar los message_id ya procesados.

# timestamp:
# Propósito: Indica la hora y fecha en que el mensaje fue publicado por el productor.
# Uso Recomendado: Útil para auditoría, diagnóstico y seguimiento de la latencia del sistema.

# priority:
# Propósito: Un valor entero que indica la prioridad relativa del mensaje (de 0 a 9, siendo 9 la más alta).
# Uso Recomendado: Solo funciona si la cola receptora está configurada como una Cola de Prioridades. Si lo está, RabbitMQ dará preferencia a los mensajes con mayor prioridad.

# expiration:
# Propósito: Especifica el tiempo de vida (TTL - Time To Live) del mensaje en la cola, en milisegundos.
# Uso Recomendado: Si el mensaje caduca antes de ser consumido, RabbitMQ lo descartará o lo moverá a la Dead Letter Queue (DLQ). Es vital para mensajes sensibles al tiempo (ej. tokens o alertas).

# user_id y app_id:
# Propósito: Identificadores que especifican qué usuario y qué aplicación generaron el mensaje.
# Uso Recomendado: Auditoría y seguridad. El broker (RabbitMQ) puede verificar que el user_id coincida con el usuario de la conexión AMQP utilizada para publicar.

# type:
# Propósito: Un identificador de aplicación para describir el "tipo" o "clase" de la carga útil del mensaje.
# Uso Recomendado: Usado a menudo para el enrutamiento interno dentro de una aplicación consumidora, similar al header Action que usas. Por ejemplo, en lugar de usar headers[:action], podrías usar properties[:type].

# cluster_id:
# Propósito: Obsoleto en AMQP 0-9-1 y no debe ser utilizado.

# persistent:
# Un valor booleano (true o false). Cuando es true, le dice a RabbitMQ que el mensaje debe persistir en el disco. Si el servidor de RabbitMQ se reinicia, el mensaje no se perderá.

# expiration:
# El tiempo de vida del mensaje en milisegundos. Después de este tiempo, RabbitMQ lo descartará automáticamente si no ha sido consumido.
module BugBunny
  class Publisher
    include ActiveModel::Model
    include ActiveModel::Attributes

    attribute :message
    attribute :pool
    attribute :routing_key, :string
    attribute :persistent, :boolean, default: false
    attribute :content_type, :string, default: "application/json"
    attribute :content_encoding, :string, default: "utf-8"
    attribute :correlation_id, :string
    attribute :reply_to, :string
    attribute :app_id, :string
    attribute :headers, default: {}
    attribute :message_id, :string, default: -> { SecureRandom.uuid }
    attribute :timestamp, :datetime, default: -> { Time.zone.now.utc.to_i }
    attribute :expiration, :integer, default: -> { 1.day.in_milliseconds } #ms
    attribute :exchange_name, :string
    attribute :exchange_type, :string, default: 'direct'
    attr_accessor :type

    attribute :action, :string
    attribute :arguments, default: {}

    def publish!
      pool.with do |conn|
        app = Rabbit.new(connection: conn)
        app.build_exchange(name: exchange_name, type: exchange_type)
        app.publish!(message, publish_opts)
      end
    end

    def publish_and_consume!
      pool.with do |conn|
        app = Rabbit.new(connection: conn)
        app.build_exchange(name: exchange_name, type: exchange_type)
        app.publish_and_consume!(message, publish_opts)
      end
    end

    def publish_opts
      { routing_key: routing_key,
        type: type,
        persistent: persistent,
        content_type: content_type,
        content_encoding: content_encoding,
        correlation_id: correlation_id,
        reply_to: reply_to,
        app_id: app_id,
        headers: headers,
        timestamp: timestamp,
        expiration: expiration }
    end

    def type
      return if action.blank?

      self.type = format(action, arguments)
    end

    def initialize(attrs = {})
      super(attrs)
      self.routing_key ||= self.class::ROUTING_KEY
    end
  end
end
