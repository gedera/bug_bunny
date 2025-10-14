# BugBunny

## Configuration

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
