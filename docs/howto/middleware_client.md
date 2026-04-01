# Client Middleware

The client middleware stack wraps outgoing requests in an onion (Faraday-style). Each middleware can inspect and modify the request before it reaches the producer, and inspect the response on the way back.

## Built-in Middlewares

### `BugBunny::Middleware::RaiseError`

Maps HTTP-like status codes in the response to Ruby exceptions:

| Status | Exception |
|--------|-----------|
| 400    | `BugBunny::BadRequest` |
| 401    | `BugBunny::Unauthorized` |
| 403    | `BugBunny::Forbidden` |
| 404    | `BugBunny::NotFound` |
| 409    | `BugBunny::Conflict` |
| 422    | `BugBunny::UnprocessableEntity` |
| 4xx    | `BugBunny::ClientError` |
| 500    | `BugBunny::InternalServerError` |
| 5xx    | `BugBunny::ServerError` |
| Timeout| `BugBunny::RequestTimeout` |

### `BugBunny::Middleware::JsonResponse`

Parses the response body from JSON and returns a `HashWithIndifferentAccess`. Without this middleware, the response body is a raw String.

---

## Using Middlewares with Client

```ruby
pool   = ConnectionPool.new(size: 5, timeout: 5) { BugBunny.create_connection }
client = BugBunny::Client.new(pool: pool) do |stack|
  stack.use BugBunny::Middleware::RaiseError
  stack.use BugBunny::Middleware::JsonResponse
  stack.use MyLoggingMiddleware
end
```

Middlewares execute in the order they are registered (FIFO). `RaiseError` and `JsonResponse` should be registered in that order so that `RaiseError` sees the parsed body.

---

## Writing a Custom Middleware

Inherit from `BugBunny::Middleware::Base` and implement `call`:

```ruby
class RequestLoggingMiddleware < BugBunny::Middleware::Base
  def call(request)
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    response = app.call(request)
    duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

    Rails.logger.info("amqp_request path=#{request.path} method=#{request.method} duration_s=#{duration.round(4)}")
    response
  end
end
```

`app.call(request)` invokes the next middleware in the stack (or the producer at the end of the chain). The return value is the response hash `{ 'status' => Integer, 'body' => ..., 'headers' => Hash }`.

### Modifying the request

```ruby
class InjectTraceHeaderMiddleware < BugBunny::Middleware::Base
  def call(request)
    request.headers['X-Trace-Id'] = MyTracer.current_trace_id
    app.call(request)
  end
end
```

### Modifying the response

```ruby
class ResponseCachingMiddleware < BugBunny::Middleware::Base
  def call(request)
    cached = Cache.get(request.path)
    return cached if cached

    response = app.call(request)
    Cache.set(request.path, response, ttl: 30) if response['status'] == 200
    response
  end
end
```

---

## Middlewares on Resource

`BugBunny::Resource` uses `RaiseError` and `JsonResponse` by default. Add custom middlewares via the class-level DSL:

```ruby
class RemoteNode < BugBunny::Resource
  client_middleware do |stack|
    stack.use RequestLoggingMiddleware
    stack.use InjectTraceHeaderMiddleware
  end
end
```

Custom middlewares are injected after the core ones, so `RaiseError` and `JsonResponse` always run first.

Middlewares defined in a parent class are inherited:

```ruby
class ApplicationResource < BugBunny::Resource
  client_middleware do |stack|
    stack.use InjectTraceHeaderMiddleware
  end
end

class RemoteNode < ApplicationResource
  # inherits InjectTraceHeaderMiddleware
end
```
