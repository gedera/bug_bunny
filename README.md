# BugBunny

[![Gem Version](https://badge.fury.io/rb/bug_bunny.svg)](https://badge.fury.io/rb/bug_bunny)

RESTful messaging over RabbitMQ for Ruby microservices.

BugBunny maps AMQP messages to controllers, routes, and models using the same patterns as Rails. Services communicate through RabbitMQ without HTTP coupling, with full support for synchronous RPC and fire-and-forget publishing.

---

## Installation

```ruby
gem 'bug_bunny'
```

```bash
bundle install
rails generate bug_bunny:install  # Rails only
```

---

## Quickstart

BugBunny connects two services through RabbitMQ. One service hosts the consumer (server side); the other uses a Resource or Client to call it (client side).

### Service B — Consumer

```ruby
# config/initializers/bug_bunny.rb
BugBunny.configure do |config|
  config.host     = ENV.fetch('RABBITMQ_HOST', 'localhost')
  config.port     = 5672
  config.username = ENV.fetch('RABBITMQ_USER', 'guest')
  config.password = ENV.fetch('RABBITMQ_PASS', 'guest')
end

# config/initializers/bug_bunny_routes.rb
BugBunny.routes.draw do
  resources :nodes
end

# app/controllers/bug_bunny/controllers/nodes_controller.rb
module BugBunny
  module Controllers
    class NodesController < BugBunny::Controller
      def show
        node = Node.find(params[:id])
        render status: :ok, json: node.as_json
      end

      def index
        render status: :ok, json: Node.all.map(&:as_json)
      end
    end
  end
end

# Worker entrypoint (dedicated thread or process)
consumer = BugBunny::Consumer.new
consumer.subscribe(
  queue_name:    'inventory_queue',
  exchange_name: 'inventory',
  routing_key:   'nodes'
)
```

### Service A — Producer

```ruby
# config/initializers/bug_bunny.rb — same connection config as above

# Pool shared across threads (Puma / Sidekiq)
BUG_BUNNY_POOL = ConnectionPool.new(size: 5, timeout: 5) do
  BugBunny.create_connection
end

class RemoteNode < BugBunny::Resource
  self.exchange      = 'inventory'
  self.resource_name = 'nodes'

  attribute :name,   :string
  attribute :status, :string
end

RemoteNode.connection_pool = BUG_BUNNY_POOL

# Use it like ActiveRecord
node = RemoteNode.find('node-123')   # GET nodes/node-123 via RabbitMQ
node.status = 'active'
node.save                            # PUT nodes/node-123

RemoteNode.where(status: 'active')  # GET nodes?status=active
RemoteNode.create(name: 'web-01', status: 'pending')
```

---

## Modes of Use

**Resource ORM** — ActiveRecord-like model for a remote service. Handles CRUD, validations, change tracking, and typed or dynamic attributes. Best when you own both sides of the communication.

**Direct Client** — `BugBunny::Client` for explicit RPC or fire-and-forget calls with full middleware control. Best when calling external services or when you need precise control over the request.

**Consumer** — Subscribe loop that routes incoming messages to controllers, with a middleware stack for cross-cutting concerns (tracing, auth, auditing).

---

## Configuration

```ruby
BugBunny.configure do |config|
  # Connection — required
  config.host     = 'localhost'
  config.port     = 5672
  config.username = 'guest'
  config.password = 'guest'
  config.vhost    = '/'

  # Resilience
  config.max_reconnect_attempts    = 10    # nil = infinite
  config.max_reconnect_interval    = 60    # seconds, ceiling for backoff
  config.network_recovery_interval = 5     # seconds, base for exponential backoff

  # Timeouts
  config.rpc_timeout         = 30   # seconds, for synchronous RPC calls
  config.connection_timeout  = 10
  config.read_timeout        = 10
  config.write_timeout       = 10

  # AMQP defaults applied to all exchanges and queues
  config.exchange_options = { durable: true }
  config.queue_options    = { durable: true }

  # Controller namespace (default: 'BugBunny::Controllers')
  config.controller_namespace = 'MyApp::RabbitHandlers'

  # Logger — any object responding to debug/info/warn/error
  config.logger = Rails.logger

  # Health check file for Kubernetes / Docker Swarm liveness probes
  config.health_check_file = '/tmp/bug_bunny_health'
end
```

`BugBunny.configure` validates all required fields on exit. A missing or invalid value raises `BugBunny::ConfigurationError` immediately, before any connection attempt.

---

## Routing DSL

```ruby
BugBunny.routes.draw do
  resources :users                    # GET/POST users, GET/PUT/DELETE users/:id
  resources :orders, only: [:index, :show, :create]

  resources :nodes do
    member   { put :drain }           # PUT nodes/:id/drain
    collection { post :rebalance }    # POST nodes/rebalance
  end

  namespace :api do
    namespace :v1 do
      resources :metrics              # Routes to Api::V1::MetricsController
    end
  end

  get  'status',     to: 'health#show'
  post 'events/:id', to: 'events#track'
end
```

---

## Direct Client

```ruby
pool   = ConnectionPool.new(size: 5, timeout: 5) { BugBunny.create_connection }
client = BugBunny::Client.new(pool: pool) do |stack|
  stack.use BugBunny::Middleware::RaiseError
  stack.use BugBunny::Middleware::JsonResponse
end

# Synchronous RPC
response = client.request('users/42', method: :get)
response['body']  # => { 'id' => 42, 'name' => 'Alice' }

# Fire-and-forget
client.publish('events', body: { type: 'user.signed_in', user_id: 42 })

# With params
client.request('users', method: :get, params: { role: 'admin', page: 2 })
```

---

## Consumer Middleware

Middlewares run before every message reaches the router. Use them for distributed tracing, authentication, or audit logging.

```ruby
class TracingMiddleware < BugBunny::ConsumerMiddleware::Base
  def call(delivery_info, properties, body)
    trace_id = properties.headers&.dig('X-Trace-Id')
    MyTracer.with_trace(trace_id) { @app.call(delivery_info, properties, body) }
  end
end

BugBunny.consumer_middlewares.use TracingMiddleware
```

---

## Observability

All internal events are emitted as structured key=value logs compatible with Datadog, CloudWatch, and ELK.

```
component=bug_bunny event=consumer.message_processed status=200 duration_s=0.012 controller=NodesController action=show
component=bug_bunny event=consumer.execution_error error_class=RuntimeError error_message="..." duration_s=0.003
component=bug_bunny event=consumer.connection_error attempt_count=2 retry_in_s=10 error_message="..."
```

Sensitive keys (`password`, `token`, `secret`, `api_key`, `authorization`, etc.) are automatically filtered to `[FILTERED]` in all log output.

---

## Documentation

- [Concepts](docs/concepts.md) — What BugBunny is, AMQP in 5 minutes, RPC vs fire-and-forget
- [Routing](docs/howto/routing.md) — Full routing DSL reference
- [Controllers](docs/howto/controller.md) — Filters, `rescue_from`, `render`, `after_action`
- [Resource ORM](docs/howto/resource.md) — CRUD, typed and dynamic attributes, `.with` scoping
- [Client Middleware](docs/howto/middleware_client.md) — Request/response middleware stack
- [Consumer Middleware](docs/howto/middleware_consumer.md) — Message processing middleware stack
- [Distributed Tracing](docs/howto/tracing.md) — Propagating trace context through RPC cycles
- [Rails Setup](docs/howto/rails.md) — Full integration: Puma, Sidekiq, Zeitwerk, health checks
- [Testing](docs/howto/testing.md) — Unit and integration testing with Bunny mocks

---

## License

[MIT](https://opensource.org/licenses/MIT)
