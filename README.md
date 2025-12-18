# BugBunny
## Configuration

```ruby
rails g bug_bunny:install
```

```ruby
config/initializers/bug_bunny.rb
BugBunny.configure do |config|
  config.host = 'Host'
  config.username = 'Username'
  config.password = 'Password'
  config.vhost = '/'
  config.logger = Rails.logger
  config.automatically_recover = false
  config.network_recovery_interval = 5
  config.connection_timeout = 10
  config.read_timeout = 30
  config.write_timeout = 30
  config.heartbeat = 15
  config.continuation_timeout = 15_000
end
```

## Publish

### Rutas

```
# config/rabbit_rest.yml
default: &default
  healt_check:
    up: 'healt_check/up'
  manager:
      services:
        index: 'services/index'
        create: 'services/create'
        show: 'services/%<id>s/show'
        update: 'services/%<id>s/update'
        destroy: 'services/%<id>s/destroy'
      swarm:
        info: 'swarm/info'
        version: 'swarm/version'
        swarm: 'swarm/swarm'
      tasks:
        index: 'tasks/index'

development:
  <<: *default

test:
  <<: *default

production:
  <<: *default

```

### Configuration

```ruby
# config/initializers/bug_bunny.rb
BUG_BUNNY_ENDPOINTS = Rails.application.config_for(:rabbit_rest)

BUNNY_POOL = ConnectionPool.new(size: RABBIT_MAX_THREADS) do
  BugBunny::Rabbit.create_connection(host: RABBIT_HOST, username: RABBIT_USER, password: RABBIT_PASS, vhost: RABBIT_VIRTUAL_HOST)
end
```

### Publisher

Creamos cualquier clase que herede de `BugBunny::Publisher`, luego definimos metodos de clase y dentro de cada una de ella su implementacion

1. Mensajes sincronicos

```
class Rabbit::Publisher::Manager < BugBunny::Publisher
  ROUTING_KEY = :manager
  ROUTES = BUG_BUNNY_ENDPOINTS[:manager][:swarm]

  def self.info(exchange:, message: nil)
    obj = new(pool: NEW_BUNNY_POOL, exchange_name: exchange, action: self::ROUTES[:info], message: message)
    obj.publish_and_consume!
  end

  def self.version(exchange:, message: nil)
    obj = new(pool: NEW_BUNNY_POOL, exchange_name: exchange, action: self::ROUTES[:version], message: message)
    obj.publish_and_consume!
  end
end
```

2. Mensajes Asincronicos

```
class Rabbit::Publisher::Manager < BugBunny::Publisher
  ROUTING_KEY = :manager
  ROUTES = BUG_BUNNY_ENDPOINTS[:manager][:swarm]

  def self.info(exchange:, message: nil)
    obj = new(pool: NEW_BUNNY_POOL, exchange_name: exchange, action: self::ROUTES[:info], message: message)
    obj.publish!
  end

  def self.version(exchange:, message: nil)
    obj = new(pool: NEW_BUNNY_POOL, exchange_name: exchange, action: self::ROUTES[:version], message: message)
    obj.publish!
  end
end
```

3. Attributes del objeto BugBunny::Publisher

- content_type
- content_encoding
- correlation_id
- reply_to
- message_id
- timestamp
- priority
- expiration
- user_id
- app_id
- action
- aguments
- cluster_id
- persistent
- expiration

## Consumer

```
class Rabbit::Controllers::Application < BugBunny::Controller
end

class Rabbit::Controllers::Swarm < Rabbit::Controllers::Application
  def info
    render status: :ok, json: Api::Docker.info
  end

  def version
    render status: :ok, json: Api::Docker.version
  end

  def swarm
    render status: :ok, json: Api::Docker.swarm
  end
end

```

## Resource
Solo para recursos que se adaptan al crud de rails estoy utilizando automaticamente la logica de los publicadores. Los atributos solo se ponen si son necesarios, si no la dejas vacia y actua igual que active resource.

```
class Manager::Application < BugBunny::Resource
  self.resource_path = 'rabbit/publisher/manager'

  attribute :id         # 'ID'
  attribute :version    # 'Version'
  attribute :created_at # 'CreatedAt'
  attribute :update_at  # 'UpdatedAt'
  attribute :spec       # 'Spec'
end

class Manager::Service < Manager::Application
  attribute :endpoint # 'Endpoint'
end

```

## Exceptions
- Error General:
 - `BugBunny::Error` hereda de `::StandardError` (Captura cualquier error de la gema.)
- Error de Publicadores:
 - `BugBunny::PublishError` hereda de `BugBunny::Error` (Para fallos de envío o conexión.)
- Error de Respuestas:
 - `BugBunny::ResponseError::Base` hereda de `BugBunny::Error` (Captura todos los errores de respuesta).
- Errores Específicos de Respuesta:
 - `BugBunny::ResponseError::BadRequest`
 - `BugBunny::ResponseError::NotFound`
 - `BugBunny::ResponseError::NotAcceptable`
 - `BugBunny::ResponseError::RequestTimeout`
 - `BugBunny::ResponseError::UnprocessableEntity`: En este el error viene el error details a lo rails.
 - `BugBunny::ResponseError::InternalServerError`
## Documentation
- *host*: Especifica la dirección de red (hostname o IP) donde se está ejecutando el servidor RabbitMQ.
- *username*: El nombre de usuario que se utiliza para la autenticación.
- *password*: La contraseña para la autenticación.
- *vhost*: Define el Virtual Host (VHost) al que se conectará la aplicación. Un VHost actúa como un namespace virtual dentro del broker, aislando entornos y recursos.
- *logger*: Indica a Bunny que use el sistema de logging estándar de Rails, integrando los mensajes del cliente AMQP con el resto de los logs de tu aplicación.

## Resiliencia y Recuperación Automática
Estos parámetros son fundamentales para manejar fallos de red y garantizar que la aplicación se recupere sin intervención manual.

- *automatically_recover*: Indica al cliente Bunny que debe intentar automáticamente reestablecer la conexión y todos los recursos asociados (canales, colas, exchanges) si la conexión se pierde debido a un fallo de red o un reinicio del broker. Nota: Este parámetro puede entrar en conflicto con un bucle de retry manual).
- *network_recovery_interval*: El tiempo que Bunny esperará entre intentos consecutivos de reconexión de red.
- *heartbeat*: El intervalo de tiempo (en segundos) en el que el cliente y el servidor deben enviarse un pequeño paquete ("latido"). Si no se recibe un heartbeat durante dos intervalos consecutivos, se asume que la conexión ha muerto (generalmente por un fallo de red o un proceso colgado), lo que dispara el mecanismo de recuperación.

## Tiempos de Espera (Timeouts)
 Estos parámetros previenen que la aplicación se bloquee indefinidamente esperando una respuesta del servidor.

- *connection_timeout*: Tiempo máximo (en segundos) que Bunny esperará para establecer la conexión TCP inicial con el servidor RabbitMQ.
- *read_timeout*: Tiempo máximo (en segundos) que la conexión esperará para leer datos del socket. Si el servidor se queda en silencio por más de 30 segundos, el socket se cerrará.
- *write_timeout*: Tiempo máximo (en segundos) que la conexión esperará para escribir datos en el socket. Útil para manejar escenarios donde la red es lenta o está congestionada.
- *continuation_timeout*: Es un timeout interno de protocolo AMQP (dado en milisegundos). Define cuánto tiempo esperará el cliente para que el servidor responda a una operación que requiere múltiples frames o pasos (como una transacción o una confirmación compleja). En este caso, son 15 segundos.
