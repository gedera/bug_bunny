# Consumer Middleware

The consumer middleware stack runs before every message reaches the router. It is the right place for cross-cutting concerns: distributed tracing, authentication, audit logging, rate limiting.

## Execution Order

```
RabbitMQ message arrives
        |
        v
ConsumerMiddleware::Stack
  Middleware A (first registered)
    Middleware B
      Middleware C
        process_message (router → controller → action)
      Middleware C (post-processing)
    Middleware B (post-processing)
  Middleware A (post-processing)
```

Middlewares execute FIFO. If no middlewares are registered, the overhead is zero.

---

## Writing a Middleware

Inherit from `BugBunny::ConsumerMiddleware::Base` and implement `call`:

```ruby
class TracingMiddleware < BugBunny::ConsumerMiddleware::Base
  def call(delivery_info, properties, body)
    trace_id = properties.headers&.dig('X-Trace-Id') || SecureRandom.uuid
    MyTracer.with_trace(trace_id) do
      @app.call(delivery_info, properties, body)
    end
  end
end
```

`@app.call(delivery_info, properties, body)` passes control to the next middleware. Always call it (unless you intentionally want to halt processing).

### Available data

| Argument | Type | Contents |
|---|---|---|
| `delivery_info` | `Bunny::DeliveryInfo` | `routing_key`, `exchange`, `delivery_tag`, `redelivered` |
| `properties` | `Bunny::MessageProperties` | `headers` (custom AMQP headers), `correlation_id`, `reply_to`, `content_type` |
| `body` | `String` | Raw message payload (typically JSON) |

### Post-processing

Code after `@app.call` runs once the message has been fully processed (controller action completed):

```ruby
class AuditMiddleware < BugBunny::ConsumerMiddleware::Base
  def call(delivery_info, properties, body)
    @app.call(delivery_info, properties, body)
  rescue => e
    AuditLog.record_failure(routing_key: delivery_info.routing_key, error: e.class.name)
    raise
  ensure
    AuditLog.record_received(routing_key: delivery_info.routing_key)
  end
end
```

---

## Registering Middlewares

```ruby
# After BugBunny.configure
BugBunny.consumer_middlewares.use TracingMiddleware
BugBunny.consumer_middlewares.use AuditMiddleware
BugBunny.consumer_middlewares.use AuthenticationMiddleware
```

Registrations are thread-safe. You can register middlewares at any point before the Consumer starts subscribing.

---

## Auto-registration from External Gems

Integration gems can register themselves transparently when required, without the user modifying the `configure` block:

```ruby
# lib/my_tracing_gem/bug_bunny.rb
require 'my_tracing_gem/bug_bunny/consumer_middleware'
BugBunny.consumer_middlewares.use MyTracingGem::BugBunny::ConsumerMiddleware
```

The user only needs:

```ruby
require 'my_tracing_gem/bug_bunny'
```

---

## Halting Message Processing

To reject a message without routing it (e.g., authentication failure):

```ruby
class AuthMiddleware < BugBunny::ConsumerMiddleware::Base
  def call(delivery_info, properties, body)
    token = properties.headers&.dig('X-Service-Token')
    unless TokenValidator.valid?(token)
      # Do not call @app — message is effectively dropped from this consumer's perspective
      # The channel will nack/reject it based on the consumer's error handling
      return
    end

    @app.call(delivery_info, properties, body)
  end
end
```

Note: halting in a middleware skips all routing and controller logic, but the message is still acknowledged at the AMQP level (the Consumer's normal ack happens in `process_message`, which was never reached). If you need to nack/reject, interact with `delivery_info.delivery_tag` directly — but this is an advanced use case.

---

## Inspecting the Stack

```ruby
BugBunny.consumer_middlewares.empty?  # => false if any middleware registered
```
