## FAQ — External (Integrator / Consumer of BugBunny)

### How do I set up BugBunny in a Rails app?

Add to Gemfile: `gem 'bug_bunny'` and `gem 'connection_pool'`. Run `rails generate bug_bunny:install`. Edit `config/initializers/bug_bunny.rb` with your RabbitMQ credentials. Create a pool: `MY_POOL = ConnectionPool.new(size: 5) { BugBunny.create_connection }`. Assign it: `BugBunny::Resource.connection_pool = MY_POOL`. See `docs/howto/rails.md` for the complete setup.

---

### How do I make an RPC call (blocking request)?

Use `Resource.find` / `Resource.where` / `Resource.create` — they all do RPC internally. For lower-level control: `client.request('users/1', method: :get, exchange: 'users_exchange', routing_key: 'users')`. The call blocks until the remote service replies or `rpc_timeout` expires.

---

### How do I publish without waiting for a reply?

Use `client.publish('events', method: :post, exchange: 'events_exchange', routing_key: 'events', body: { ... })`. Fire-and-forget — does not block. No RPC timeout applies.

---

### What happens when `find` returns nil vs raises?

`Resource.find` returns `nil` on 404 (does not raise). `Resource.where` returns `[]` on 404. Both raise `BugBunny::RequestTimeout` if the remote service does not reply within `rpc_timeout`. They raise `BugBunny::ServerError` on 5xx responses.

---

### How do I handle validation errors from the remote service?

`resource.save` returns `false` on 422 and loads the remote errors into `resource.errors`. Check `resource.valid?` then `resource.errors.full_messages`. The remote service must render `{ errors: { field: ['message'] } }` for the errors to be auto-loaded.

---

### How do I use `.with` to override the exchange per call?

```ruby
# Block form (preferred — thread-safe, restores after block)
Order.with(exchange: 'priority_exchange', routing_key: 'priority') do
  Order.find(id)
end

# Single-call proxy
Order.with(exchange: 'priority_exchange').find(id)
# ScopeProxy is single-use — calling a second method raises BugBunny::Error
```

---

### How do I define a Resource with typed attributes?

```ruby
class User < BugBunny::Resource
  self.exchange = 'users_exchange'

  attribute :id,    :integer
  attribute :name,  :string
  attribute :email, :string

  validates :name, presence: true
end
```

Typed attributes get ActiveModel coercion and dirty tracking. Attributes not declared with `attribute` are handled dynamically via `method_missing` and tracked in `@extra_attributes`.

---

### How do I add client-side middleware to a Resource?

```ruby
class Order < BugBunny::Resource
  client_middleware do |stack|
    stack.use MyRetryMiddleware
  end
end
```

Middlewares are inherited by subclasses and applied in registration order (first = outermost). `RaiseError` and `JsonResponse` are always added as the innermost middlewares by `Resource` — do not add them manually.

---

### How do I run the Consumer in a Rails app?

The Consumer is a blocking loop. Run it in a separate process, not inside Puma:

```ruby
# lib/tasks/rabbit.rake
task consumer: :environment do
  conn = BugBunny.create_connection
  consumer = BugBunny::Consumer.new(conn)
  trap('TERM') { consumer.shutdown; exit }
  trap('INT')  { consumer.shutdown; exit }
  consumer.subscribe(
    queue_name: 'my_queue', exchange_name: 'my_exchange', routing_key: 'my_key'
  )
end
```

---

### How do I write a Controller?

Subclass `BugBunny::Controller`. Place it in the namespace from `config.controller_namespace` (default: `BugBunny::Controllers`). Implement action methods (`index`, `show`, `create`, `update`, `destroy` or custom). Call `render(status:, json:)` to respond. The Consumer routes messages to `YourController.call(headers:, body:)`.

---

### How do I propagate trace context through RabbitMQ?

On the consumer side, inject headers into replies:
```ruby
config.rpc_reply_headers = -> { { 'X-Trace-Id' => Tracer.current } }
```
On the producer side, hydrate context from the reply:
```ruby
config.on_rpc_reply = ->(headers) { Tracer.hydrate(headers['X-Trace-Id']) }
```
For consumer-side middleware (propagating from incoming request), use `ConsumerMiddleware`.

---

### How do I configure health checks for Kubernetes?

Set `config.health_check_file = '/app/tmp/bug_bunny_health'`. BugBunny touches that file every `health_check_interval` seconds (default: 60) after verifying the RabbitMQ connection. Add a `livenessProbe` in your Kubernetes manifest checking for that file's existence.

---

### What is the default RPC timeout and how do I change it?

Default: 10 seconds. Override globally: `config.rpc_timeout = 30`. Override per request: `client.request('users/1', method: :get, exchange: ..., timeout: 5)`. When exceeded, `BugBunny::RequestTimeout` is raised.

---

### Do I need to declare exchanges and queues manually?

No. BugBunny declares them automatically when `subscribe` (consumer) or the first RPC call (producer) is made. Use `config.exchange_options` and `config.queue_options` for global defaults (e.g., `{ durable: true }`). Override per resource with `Resource.exchange_options=` or per call with `.with(exchange_options:)`.
