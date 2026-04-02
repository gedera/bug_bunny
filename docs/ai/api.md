## Public API

### BugBunny.configure

```ruby
BugBunny.configure do |config|
  config.host     = 'localhost'       # String, required
  config.port     = 5672              # Integer 1..65535, required
  config.username = 'guest'           # String, required
  config.password = 'guest'           # String, required
  config.vhost    = '/'               # String, required

  config.rpc_timeout            = 10   # Integer 1..3600, seconds
  config.channel_prefetch       = 1    # Integer 1..10000
  config.max_reconnect_attempts = nil  # nil = infinite
  config.max_reconnect_interval = 60   # seconds, backoff ceiling
  config.network_recovery_interval = 5 # seconds, backoff base

  config.exchange_options = { durable: true }
  config.queue_options    = { durable: true }

  config.logger             = Rails.logger
  config.health_check_file  = Rails.root.join('tmp/bug_bunny_health').to_s

  config.controller_namespace = 'Rabbit::Controllers'

  # Trace propagation hooks
  config.rpc_reply_headers = -> { { 'X-Trace-Id' => Tracer.current_header } }
  config.on_rpc_reply      = ->(headers) { Tracer.hydrate(headers['X-Trace-Id']) }
end
```

`validate!` is called automatically at the end of `configure`. Raises `BugBunny::ConfigurationError` on invalid values.

---

### BugBunny.routes

```ruby
BugBunny.routes.draw do
  resources :users                          # index, show, create, update, destroy
  resources :orders do
    member     { post :cancel }             # POST orders/:id/cancel
    collection { get  :pending }            # GET  orders/pending
  end
  namespace :admin do
    resources :reports                      # Admin::Controllers::ReportsController
  end                                       # path prefix: admin/reports
end
```

**recognize:**
```ruby
BugBunny.routes.recognize('GET', '/users/42')
# => { controller: 'users', action: 'show', params: { 'id' => '42' }, namespace: nil }
```

---

### BugBunny::Controller

Controllers live in the namespace configured by `config.controller_namespace` (default: `BugBunny::Controllers`).

```ruby
class UsersController < BugBunny::Controller
  before_action :authenticate!, only: [:create, :update, :destroy]
  after_action  :emit_audit_event, only: [:create, :update, :destroy]
  around_action :wrap_transaction, only: [:create]

  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found

  def index
    render status: :ok, json: User.all
  end

  def show
    user = User.find(params[:id])
    render status: :ok, json: user
  end

  def create
    user = User.new(user_params)
    if user.save
      render status: :created, json: user
    else
      render status: :unprocessable_entity, json: { errors: user.errors }
    end
  end

  private

  def authenticate!
    render status: :unauthorized, json: { error: 'Unauthorized' } unless valid_token?
  end

  def render_not_found(e)
    render status: :not_found, json: { error: e.message }
  end
end
```

**`render` signature:**
```ruby
render(status:, json: nil, headers: {})
# status: HTTP symbol (:ok, :created, :not_found, ...) or Integer
# headers: merged into response_headers — received by on_rpc_reply
```

**`params`** — `HashWithIndifferentAccess` containing:
- Query string parameters
- `:id` extracted from the route
- JSON body (parsed automatically if `content_type` includes `json`)

**`raw_string`** — the unparsed body when content type is not JSON.

**`self.call(headers:, body:)`** — entry point called by the Consumer; returns `{ status:, headers:, body: }`.

---

### BugBunny::Resource

```ruby
class Order < BugBunny::Resource
  self.exchange      = 'orders_exchange'
  self.exchange_type = 'direct'
  self.routing_key   = 'orders'

  attribute :id,     :integer
  attribute :status, :string
  attribute :total,  :float

  validates :status, presence: true

  before_save :set_defaults
end
```

**Class methods:**

| Method | HTTP | Description |
|---|---|---|
| `find(id)` | GET `resource/id` | Returns instance or `nil` on 404 |
| `where(filters)` | GET `resource` | Returns Array, empty on 404 |
| `all` | GET `resource` | Alias for `where({})` |
| `create(attrs)` | POST `resource` | Returns instance (may have errors) |

**Instance methods:**

| Method | HTTP | Description |
|---|---|---|
| `save` | POST or PUT | POST if new, PUT if persisted. Returns Boolean. |
| `update(attrs)` | PUT | `assign_attributes` + `save` |
| `destroy` | DELETE | Returns Boolean |
| `persisted?` | — | True after successful save or find |
| `changed?` | — | True if typed or dynamic attributes changed |

**`.with` — per-call context override:**
```ruby
# Block form (thread-safe, restores context after block)
Order.with(exchange: 'other_exchange') do
  Order.find(1)
end

# Single-call proxy (single-use, raises on second call)
Order.with(routing_key: 'vip_orders').where(status: 'pending')
```

**Class-level config:**
```ruby
Order.connection_pool  = MY_POOL
Order.exchange         = 'orders_exchange'
Order.exchange_type    = 'direct'
Order.routing_key      = 'orders'
Order.resource_name    = 'orders'      # default: class name pluralized/underscored
Order.param_key        = 'order'       # default: model_name.element
Order.exchange_options = { durable: true }
Order.queue_options    = { durable: true }
```

---

### BugBunny::Client

For cases where `Resource` is too high-level:

```ruby
client = BugBunny::Client.new(pool: MY_POOL) do |stack|
  stack.use MyTracingMiddleware
  stack.use BugBunny::Middleware::RaiseError
  stack.use BugBunny::Middleware::JsonResponse
end

# RPC (blocking)
response = client.request('users/1',
  method: :get,
  exchange: 'users_exchange',
  exchange_type: 'direct',
  routing_key: 'users'
)

# Fire-and-forget
client.publish('events',
  method: :post,
  exchange: 'events_exchange',
  routing_key: 'events',
  body: { type: 'user.created', user_id: 42 }
)
```

---

### BugBunny::ConsumerMiddleware

```ruby
# Register globally
BugBunny.consumer_middlewares.use MyMiddleware

# Or via configuration
BugBunny.configure do |config|
  config.consumer_middlewares.use TracingMiddleware
end
```

**Writing a middleware:**
```ruby
class MyMiddleware
  def initialize(app)
    @app = app
  end

  def call(delivery_info, properties, body)
    # before
    @app.call(delivery_info, properties, body)
    # after
  end
end
```

---

### BugBunny.create_connection

```ruby
conn = BugBunny.create_connection   # Returns a connected Bunny::Session
```

Used to populate a `ConnectionPool`:
```ruby
MY_POOL = ConnectionPool.new(size: 5, timeout: 5) { BugBunny.create_connection }
BugBunny::Resource.connection_pool = MY_POOL
```
