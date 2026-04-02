## Antipatterns

### Running Producer and Consumer in the same process thread

**Wrong:**
```ruby
# In the same Puma process
Thread.new { BugBunny::Consumer.new(conn).subscribe(..., block: true) }
BugBunny::Resource.find(1)   # uses a different connection slot — works but is wrong architecturally
```

**Why it's wrong:** The Consumer is a blocking loop designed to run in a dedicated worker process. Running it inside Puma wastes threads and ties service lifetime to the web server. If the web server restarts, the consumer dies too.

**Correct:** Run the Consumer as a separate process (Rake task, separate container/Dockerfile).

---

### Creating a new Client or Producer per request

**Wrong:**
```ruby
def show
  client = BugBunny::Client.new(pool: MY_POOL)  # new client on every request
  client.request(...)
end
```

**Why it's wrong:** `Client` itself is cheap, but creating it with a block configures a new middleware stack. More importantly, if you bypass `Resource` and call `Producer` directly, creating a new `Producer` on an already-used channel causes an AMQP `basic_consume` conflict.

**Correct:** Use `Resource` (which caches Client → Session → Producer per connection slot) or create the `Client` once at application boot.

---

### Setting `Resource.connection_pool` inside a request

**Wrong:**
```ruby
class OrdersController < ApplicationController
  def index
    BugBunny::Resource.connection_pool = ConnectionPool.new(...) { BugBunny.create_connection }
    Order.all
  end
end
```

**Why it's wrong:** The pool is a global class-level setting. Reassigning it in a request creates a race condition and leaks connections.

**Correct:** Set `connection_pool` once in the initializer at boot.

---

### Calling `.with` proxy more than once

**Wrong:**
```ruby
scope = Order.with(exchange: 'priority')
scope.find(1)
scope.find(2)   # raises BugBunny::Error — ScopeProxy is single-use
```

**Why it's wrong:** `ScopeProxy#method_missing` sets `@used = true` on the first call. A second call raises.

**Correct:** Use the block form of `.with` for multiple calls within the same scope:
```ruby
Order.with(exchange: 'priority') do
  Order.find(1)
  Order.find(2)
end
```

---

### Adding `RaiseError` or `JsonResponse` manually to a Resource middleware stack

**Wrong:**
```ruby
class Order < BugBunny::Resource
  client_middleware do |stack|
    stack.use BugBunny::Middleware::RaiseError    # already added by Resource
    stack.use BugBunny::Middleware::JsonResponse  # already added by Resource
  end
end
```

**Why it's wrong:** `Resource#bug_bunny_client` always adds `RaiseError` and `JsonResponse` as the innermost middlewares. Adding them again wraps the response in a second parsing pass, causing errors.

**Correct:** Only add custom middlewares in `client_middleware`. Never add the built-ins.

---

### Calling `render` multiple times in an action or filter

**Wrong:**
```ruby
def show
  render status: :ok, json: user
  render status: :not_found, json: { error: 'Not found' }  # second render — first one wins
end
```

**Why it's wrong:** The second `render` call overwrites `@rendered_response`. Behavior is undefined and dependent on execution order.

**Correct:** Use early returns or `return render(...)` to ensure only one render is called.

---

### Raising exceptions from `rpc_reply_headers` or `on_rpc_reply`

**Wrong:**
```ruby
config.rpc_reply_headers = -> { { 'X-Trace-Id' => Tracer.header! } }  # Tracer.header! may raise
```

**Why it's wrong:** An exception in `rpc_reply_headers` propagates into the Consumer's `reply` method, corrupting the RPC reply and causing the caller to timeout.

**Correct:** Wrap the proc body in a rescue:
```ruby
config.rpc_reply_headers = -> { { 'X-Trace-Id' => (Tracer.header rescue nil) } }
```

---

### Declaring exchanges with incompatible options after first declaration

**Wrong:**
```ruby
# Service A declares exchange as non-durable
BugBunny.configure { |c| c.exchange_options = { durable: false } }

# Service B (or a later boot) declares the same exchange as durable
BugBunny.configure { |c| c.exchange_options = { durable: true } }
```

**Why it's wrong:** RabbitMQ raises a channel error (406 PRECONDITION_FAILED) if you try to redeclare an exchange with different attributes. This crashes the channel.

**Correct:** Agree on exchange options across all services. Use `{ durable: true }` in all production services.

---

### Using `Resource` without a connection pool

**Wrong:**
```ruby
Order.find(1)  # BugBunny::Error: Connection pool missing for Order
```

**Why it's wrong:** `Resource.bug_bunny_client` raises if `connection_pool` is nil.

**Correct:** Always set `BugBunny::Resource.connection_pool` (or a subclass-specific pool) before making calls. Do this in the initializer.

---

### Calling `logger.debug "..."` directly inside BugBunny classes

**Wrong:**
```ruby
logger.debug "Processing #{message}"  # eager interpolation, ignores debug level
```

**Why it's wrong:** String interpolation happens regardless of log level, wasting CPU. Also bypasses `safe_log`'s sensitive key filtering.

**Correct:**
```ruby
safe_log(:debug, 'component.event', key: value)
# safe_log passes blocks to logger.debug { ... } internally
```
