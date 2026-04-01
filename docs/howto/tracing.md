# Distributed Tracing

BugBunny propagates trace context through the full RPC cycle, from the producer to the consumer and back. The mechanism is tracer-agnostic: BugBunny provides hooks and you supply the tracer-specific logic.

## What BugBunny Propagates by Default

The `correlation_id` AMQP property travels automatically from producer to consumer on every request. The Consumer wraps the entire execution in a `logger.tagged(correlation_id)` block when the logger supports tagged logging (Rails' `ActiveSupport::TaggedLogging`).

This alone connects producer and consumer log lines without any configuration.

---

## Full Bidirectional Propagation

For distributed tracing systems (OpenTelemetry, AWS X-Ray, Datadog APM, etc.) you need to:

1. **Inject** the current trace header into outgoing requests (producer side).
2. **Extract** the trace header from incoming messages (consumer side) — done via Consumer Middleware.
3. **Re-inject** the updated trace header into the RPC reply (consumer side).
4. **Hydrate** the trace context from the reply headers back in the calling thread (producer side).

Steps 3 and 4 handle the case where the consumer creates a child span — the parent needs to know about it.

---

## Configuration Hooks

### `rpc_reply_headers`

A `Proc` called in the consumer thread just before sending the RPC reply. Its return value is merged into the reply AMQP headers.

```ruby
BugBunny.configure do |config|
  config.rpc_reply_headers = -> {
    { 'X-Trace-Header' => MyTracer.outgoing_header }
  }
end
```

Zero overhead when not set.

### `on_rpc_reply`

A `Proc` called in the producer thread after the RPC reply arrives, with the reply headers as argument. Use it to hydrate the trace context in the calling thread.

```ruby
BugBunny.configure do |config|
  config.on_rpc_reply = ->(headers) {
    MyTracer.hydrate(headers['X-Trace-Header'])
  }
end
```

---

## Full Example (tracer-agnostic)

```ruby
# config/initializers/bug_bunny.rb

BugBunny.configure do |config|
  # ... connection config ...

  # Step 3: inject updated trace header into RPC reply
  config.rpc_reply_headers = -> {
    { 'X-Trace-Header' => MyTracer.generate_outgoing_header }
  }

  # Step 4: hydrate trace context in the producer thread after reply
  config.on_rpc_reply = ->(headers) {
    MyTracer.hydrate_from_header(headers['X-Trace-Header'])
  }
end

# Step 1: inject trace header into outgoing requests (client middleware)
class TraceInjectionMiddleware < BugBunny::Middleware::Base
  def call(request)
    request.headers['X-Trace-Header'] = MyTracer.generate_outgoing_header
    app.call(request)
  end
end

# Step 2: extract trace header from incoming messages (consumer middleware)
class TraceExtractionMiddleware < BugBunny::ConsumerMiddleware::Base
  def call(delivery_info, properties, body)
    incoming_header = properties.headers&.dig('X-Trace-Header')
    MyTracer.with_trace_from_header(incoming_header) do
      @app.call(delivery_info, properties, body)
    end
  end
end

# Register both
BugBunny::Resource.client_middleware { |s| s.use TraceInjectionMiddleware }
BugBunny.consumer_middlewares.use TraceExtractionMiddleware
```

---

## Fire-and-Forget Tracing

For `:publish` (fire-and-forget) calls, there is no reply, so `on_rpc_reply` and `rpc_reply_headers` do not apply. Use only the client middleware to inject the outgoing trace header:

```ruby
class TraceInjectionMiddleware < BugBunny::Middleware::Base
  def call(request)
    request.headers['X-Trace-Header'] = MyTracer.generate_outgoing_header
    app.call(request)
  end
end
```

The consumer middleware extracts it on the other side regardless of whether the call was RPC or fire-and-forget.

---

## correlation_id

BugBunny sets `correlation_id` automatically on every RPC request (used internally to match replies). It is also forwarded as a log tag. If your tracer uses a separate header (e.g., `traceparent`), use the `X-Trace-Header` pattern above. If you want to use `correlation_id` as the trace ID, read it from `properties.correlation_id` in your consumer middleware.
