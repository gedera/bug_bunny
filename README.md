# BugBunny

[![Gem Version](https://badge.fury.io/rb/bug_bunny.svg)](https://badge.fury.io/rb/bug_bunny)

RESTful messaging over RabbitMQ for Ruby microservices.

BugBunny maps AMQP messages to controllers, routes, and models using the same patterns as Rails. Services communicate through RabbitMQ without HTTP coupling, with full support for synchronous RPC, fire-and-forget publishing, and sync publisher confirms for delivery-critical events.

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

  # AMQP defaults applied to all exchanges and queues.
  # Gem defaults (since 4.16):
  #   DEFAULT_EXCHANGE_OPTIONS = { durable: false, auto_delete: false }
  #   DEFAULT_QUEUE_OPTIONS    = { exclusive: false, durable: true, auto_delete: false }
  # Override only if your service needs different infrastructure semantics.
  config.exchange_options = { durable: true }
  config.queue_options    = { durable: true }

  # Controller namespace (default: 'BugBunny::Controllers')
  config.controller_namespace = 'MyApp::RabbitHandlers'

  # Logger — any object responding to debug/info/warn/error
  config.logger = Rails.logger

  # Health check file for Kubernetes / Docker Swarm liveness probes
  config.health_check_file = '/tmp/bug_bunny_health'

  # Publisher Confirms — fail-loud defaults (both flags default to true).
  # Set to false to restore legacy log-only behavior.
  config.nack_raise   = true   # broker NACK → raise BugBunny::PublishNacked
  config.return_raise = true   # broker basic.return (mandatory) → raise BugBunny::PublishUnroutable

  # Callback invoked when the broker returns an unroutable mandatory message.
  # Runs BEFORE PublishUnroutable is raised (if return_raise is true).
  # When nil (default), BugBunny logs the return as `session.broker_return` at :warn.
  # Signature: ->(return_info, properties, body) { ... }
  config.on_return = ->(return_info, _props, body) {
    MyAlerts.publish_unroutable(rk: return_info.routing_key, body: body)
  }
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

### Gotchas

**URL is positional, not a kwarg.** The first argument of `client.request` / `client.publish` is positional. There is **no** `path:` kwarg, splatting a hash with `path:` will fail silently or raise `ArgumentError`:

```ruby
args = { exchange: 'ingest.x', body: payload }
client.publish(**args)              # ❌ ArgumentError: wrong number of arguments
client.publish('event.name', **args) # ✅
```

**Block runs after kwargs.** Keyword args are applied first; the block (if given) can override them. Use kwargs for the common case and block for atypical setup:

```ruby
client.publish('evt', exchange: 'x', persistent: true) do |req|
  req.timestamp = some_past_time   # only via block — not in REQUEST_ATTRS
end
```

### Production publisher recipe

Defaults aimed at sane microservices — declare durable exchanges, persistent messages, confirmed delivery with mandatory routing, explicit correlation id:

```ruby
client.publish('acct.start',
               exchange:         'ingest.radius',
               exchange_type:    :topic,
               exchange_options: { durable: true },   # match consumer-declared exchange
               body:             payload,
               confirmed:        true,
               mandatory:        true,                # raise PublishUnroutable if no binding
               persistent:       true,                # delivery_mode: 2 — survives broker restart
               correlation_id:   SecureRandom.uuid,
               app_id:           'radius_manager')
```

| AMQP property | Kwarg | Reason it matters for critical publishers |
|---|---|---|
| `delivery_mode` | `persistent: true` | Without it, the message lives only in broker RAM (lost on restart). Default `false`. |
| `confirmation` | `confirmed: true` | Block until the broker acks. Without it, `client.publish` returns 202 before the broker sees the message. |
| `mandatory` | `mandatory: true` | Catches misrouted publishes. Combined with `return_raise` (default `true`), raises `PublishUnroutable` instead of silently dropping. |
| `exchange durable` | `exchange_options: { durable: true }` | Match the exchange definition that consumers declare. Mismatch raises `Bunny::PreconditionFailed`. |
| `correlation_id` | `correlation_id:` | Tracing. Auto-generated when missing for RPC and for `confirmed + mandatory + return_raise`, but explicit is preferred. |

### Testing publishers

Mocks of `Client` (via `instance_double`) **do not catch arity mismatches** when the caller does splat (`**args`). Signature errors like passing `path:` as kwarg or unknown keys won't surface in unit tests with mocks. **Add a smoke integration test** for new publishers — declare an exclusive queue, bind to the exchange, publish, `queue.pop`, assert `correlation_id`, `headers`, `routing_key`, `delivery_mode`:

```ruby
RSpec.describe 'MyPublisher', :integration do
  it 'publishes with correct AMQP metadata' do
    conn = BugBunny.create_connection
    ch   = conn.create_channel
    x    = ch.topic('ingest.radius', durable: true)
    q    = ch.queue('', exclusive: true).bind(x, routing_key: 'acct.#')

    MyPublisher.call(payload)

    _delivery, props, body = q.pop(manual_ack: false)
    expect(props.correlation_id).not_to be_nil
    expect(props.delivery_mode).to eq(2)         # persistent
    expect(JSON.parse(body)).to include(...)
  ensure
    conn&.close
  end
end
```

### Publisher Confirms (delivery-critical events)

For events where you need a delivery guarantee from the broker (auditing, billing, accounting) without the cost of a full RPC, use `publish` with `confirmed: true`. The call blocks until the broker acknowledges receipt:

```ruby
client.publish('acct.start',
               exchange:        'acct_events',
               exchange_type:   'topic',
               body:            { tenant_id: 42, plan: 'pro' },
               confirmed:       true,
               mandatory:       true,    # broker returns the message if no queue is bound
               confirm_timeout: 0.5)     # seconds; nil waits forever
# => { 'status' => 202, 'body' => nil }  # broker confirmed
```

| Option | Type | Default | Purpose |
|---|---|---|---|
| `confirmed` | Boolean | `false` | Block until `wait_for_confirms` returns. |
| `mandatory` | Boolean | `false` | Broker returns the message if it cannot be routed to any queue. Requires `confirmed: true` to be useful. |
| `confirm_timeout` | Float | `nil` | Seconds to wait for the broker ACK. Raises `BugBunny::RequestTimeout` if exceeded. |
| `nack_raise` | Boolean | `nil` | Per-request override of `config.nack_raise`. When `nil`, falls back to the global flag (default `true`). |
| `return_raise` | Boolean | `nil` | Per-request override of `config.return_raise`. When `nil`, falls back to the global flag (default `true`). Requires `confirmed: true` and `mandatory: true` to take effect. |

**Two broker signals, two exceptions:**

| Broker signal | Default behavior | Exception class | Fields |
|---|---|---|---|
| `basic.nack` (explicit rejection) | Raises | `BugBunny::PublishNacked` | `path`, `nacked_count` |
| `basic.return` (unroutable + `mandatory: true`) | Raises | `BugBunny::PublishUnroutable` | `path`, `exchange`, `routing_key`, `reply_code`, `reply_text`, `correlation_id` |

Both exceptions translate naturally into HTTP 5xx in critical publishers (audit, billing, RADIUS accounting) so upstream systems retry. The `config.on_return` callback (if defined) still runs before `PublishUnroutable` is raised — useful for alerting/metrics. To restore the legacy "log-only" behaviour:

```ruby
BugBunny.configure do |c|
  c.nack_raise   = false  # or pass `nack_raise: false` per request
  c.return_raise = false  # or pass `return_raise: false` per request
end
```

When `mandatory: false` (the default), `return_raise` is inert — the broker never emits `basic.return` without mandatory.

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

BugBunny implementa de forma nativa las [OpenTelemetry semantic conventions for messaging](https://opentelemetry.io/docs/specs/otel/trace/semantic-conventions/messaging/), inyectando automáticamente campos como `messaging_system`, `messaging_operation`, `messaging_destination_name` y `messaging_message_id` tanto en los headers AMQP como en los log events estructurados.

Todos los eventos internos se emiten como logs `key=value` compatibles con Datadog, CloudWatch, ELK y ExisRay.

```
component=bug_bunny event=producer.publish method=POST path=acct/publish messaging_destination_name=acct_x messaging_routing_key=acct.start.42
component=bug_bunny event=producer.published method=POST path=acct/publish routing_key=acct.start.42 messaging_message_id=corr-1 duration_s=0.000812
component=bug_bunny event=producer.confirmed method=POST path=acct/publish routing_key=acct.start.42 publish_duration_s=0.000812 confirm_duration_s=0.012 duration_s=0.013
component=bug_bunny event=producer.rpc_response_received method=GET path=users/42 duration_s=0.034 messaging_operation=receive
component=bug_bunny event=consumer.message_processed status=200 duration_s=0.012 messaging_operation=process controller=NodesController action=show
component=bug_bunny event=consumer.execution_error error_class=RuntimeError error_message="..." duration_s=0.003
component=bug_bunny event=consumer.connection_error attempt_count=2 retry_in_s=10 error_message="..."
```

### Duraciones medidas internamente

BugBunny mide y emite duraciones automáticamente — **no es necesario envolver llamadas a `client.publish` con `Process.clock_gettime` en el código de aplicación**. Las unidades siguen las [OpenTelemetry metric semantic conventions](https://opentelemetry.io/docs/specs/semconv/general/metrics/) (`s`, segundos como `Float`).

| Evento | Duración | Mide |
|---|---|---|
| `producer.published` | `duration_s` | Solo el `basic_publish` (TCP enqueue al broker). |
| `producer.confirmed` | `publish_duration_s` + `confirm_duration_s` + `duration_s` (total) | Publish + espera de ACK del broker. |
| `producer.rpc_response_received` | `duration_s` | Round-trip RPC completo (publish + procesamiento remoto + reply). |
| `consumer.message_processed` | `duration_s` | Procesamiento del mensaje (router + controller + reply). |
| `consumer.execution_error` | `duration_s` | Tiempo transcurrido hasta el error. |

Las claves sensibles (`password`, `token`, `secret`, `api_key`, `authorization`, etc.) se filtran automáticamente a `[FILTERED]` en toda la salida de logs.

---

## Error Handling

BugBunny maps RabbitMQ responses to a semantic exception hierarchy, similar to how HTTP clients handle status codes.

### Exception Hierarchy

```
BugBunny::Error
├── CommunicationError                  (network / channel failure)
├── ConfigurationError                  (invalid config attribute)
├── SecurityError                       (unauthorized controller resolution)
├── PublishNacked                       (broker basic.nack on :confirmed publish)
├── PublishUnroutable                   (broker basic.return on mandatory + :confirmed)
├── ClientError (4xx)
│   ├── BadRequest (400)
│   ├── NotFound (404)
│   │   └── RoutingError                (consumer-side: no route for verb + path)
│   ├── NotAcceptable (406)
│   ├── RequestTimeout (408)
│   ├── Conflict (409)
│   └── UnprocessableEntity (422)
└── ServerError (5xx)
    ├── InternalServerError (500+)
    └── RemoteError (500)
```

### Remote Exception Propagation

When a controller raises an unhandled exception, BugBunny serializes it and sends it back to the caller as a 500 response. The client-side middleware reconstructs it as a `BugBunny::RemoteError` with full access to the original exception details:

```ruby
begin
  node = RemoteNode.find('node-123')
rescue BugBunny::RemoteError => e
  e.original_class     # => "TypeError"
  e.original_message   # => "nil can't be coerced into Integer"
  e.original_backtrace # => Array<String> from the remote service
rescue BugBunny::NotFound
  # Resource doesn't exist
rescue BugBunny::RequestTimeout
  # Consumer didn't respond in time
end
```

### Validation Errors

`Resource#save` returns `false` on validation failure and loads remote errors into the model:

```ruby
order = RemoteOrder.new(total: -1)
unless order.save
  order.errors.full_messages # => ["total must be greater than 0"]
end
```

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
