## Architecture

### Component Map

```
Publisher side (Service A)                Consumer side (Service B)
─────────────────────────────             ─────────────────────────────────────
Resource.find / .where / .save            Consumer#subscribe (blocking loop)
  └─ Client#request / #publish              └─ ConsumerMiddleware::Stack#call
       └─ Middleware::Stack (onion)               └─ Consumer#process_message
            └─ Producer#rpc / #fire                    └─ Router#recognize
                 └─ Session#exchange                         └─ Controller.call
                 └─ Bunny channel                                └─ action method
                      └─ RabbitMQ                                └─ render(...)
                                                           └─ Consumer#reply
```

### Session

`BugBunny::Session` wraps a Bunny channel. It caches exchange and queue objects by name to avoid redundant AMQP declarations. Cache writes are protected by a `Mutex` (double-checked locking pattern). One Session per connection slot — created lazily in `Client#session_for` and stored as an ivar on the Bunny connection object.

### Producer

`BugBunny::Producer` publishes messages. One Producer per connection slot — cached alongside the Session. Caching is mandatory: the Producer registers a `basic_consume` on the channel to listen for Direct Reply-to responses. Creating a second Producer on the same channel would trigger an AMQP error (double-consumer).

**RPC flow:**
1. `Producer#rpc` assigns a `correlation_id` and publishes with `reply_to: 'amq.rabbitmq.reply-to'`.
2. A `Concurrent::IVar` (`future`) is registered in an in-memory hash keyed by `correlation_id`.
3. A reply-listener thread sets `future.set(payload)` when the reply arrives.
4. The calling thread blocks on `future.value(timeout)`.
5. On success: `on_rpc_reply&.call(headers)` is invoked, then the response is parsed.
6. On timeout: `BugBunny::RequestTimeout` is raised.

**Fire-and-forget flow:**
`Producer#fire` publishes without `reply_to`. No blocking.

### Client

`BugBunny::Client` implements the Faraday-style Onion Middleware pattern. The final action in the chain is the call to `Producer#rpc` or `Producer#fire`. Middlewares wrap that action, each calling `app.call(request)` to continue the chain.

Built-in middlewares for `Resource`:
- `Middleware::RaiseError` — converts non-2xx status codes to exceptions.
- `Middleware::JsonResponse` — parses the JSON body and normalizes the response hash.

### Consumer

`BugBunny::Consumer` is a blocking subscribe loop intended to run in a dedicated process (not inside Puma). Responsibilities:
1. Declare exchange, queue, and binding.
2. Start a background `Concurrent::TimerTask` as a health check.
3. For each message: invoke `ConsumerMiddleware::Stack`, then `process_message`.

`process_message` flow:
1. Extract `path` from `properties.type` (or `headers['path']`).
2. Extract HTTP method from `headers['x-http-method']`.
3. Parse query string from the path.
4. Call `BugBunny.routes.recognize(method, path)` → controller + action + params.
5. Constantize the controller class; verify it inherits from `BugBunny::Controller` (RCE prevention).
6. Call `ControllerClass.call(headers:, body:)` → response hash.
7. If `reply_to` is present: publish reply with `rpc_reply_headers` injected.
8. ACK the delivery tag.

On any error: publish a 500 reply (so the RPC caller doesn't timeout), then NACK/reject.

### ConsumerMiddleware::Stack

A pipeline of middleware objects. Registration is protected by a `Mutex`. Each middleware is a class implementing `#initialize(app)` and `#call(delivery_info, properties, body)`. The terminal app is the controller dispatch lambda. Middlewares run in registration order (first registered = outermost wrapper).

### Router

`BugBunny::Routing::RouteSet` stores an array of `Route` objects. `recognize(method, path)` iterates routes looking for a match. Routes are registered via the DSL:
- `resources :users` → 5 standard routes (index, show, create, update, destroy) + member/collection.
- `namespace :admin { resources :users }` → same routes with path prefix `admin/` and namespace `Admin::Controllers`.

### Resource

`BugBunny::Resource` is an ActiveModel class. It resolves AMQP config (exchange, routing key, pool) via a 3-level cascade: thread-local (set by `.with`) → class-level → superclass. Dirty tracking covers both typed `attribute` columns (via ActiveModel::Dirty) and dynamic attributes (via `@extra_attributes` + `@dynamic_changes`).

### Configuration Cascade (Resource)

```
Thread.current["bb_#{object_id}_exchange"]   ← .with(exchange:) sets this
  ↓ (nil fallback)
Resource.exchange=                            ← class-level static config
  ↓ (nil fallback)
ParentResource.exchange=                      ← walks superclass chain
```

Same cascade for: `routing_key`, `exchange_type`, `pool`, `exchange_options`, `queue_options`.

### Observability

All BugBunny classes include `BugBunny::Observability`. `safe_log` formats structured log lines as `component=x event=clase.evento [key=value ...]` and filters sensitive keys (`password`, `token`, `secret`, `api_key`, `auth`, etc.). Log failures are swallowed — they never affect the main flow.
