# Concepts

## What is BugBunny?

BugBunny is a Ruby gem that implements a RESTful routing layer over AMQP (RabbitMQ). It lets microservices communicate through RabbitMQ using familiar HTTP-like patterns: verbs (GET, POST, PUT, DELETE), controllers, declarative routes, synchronous RPC, and fire-and-forget publishing.

**Problem it solves:** Direct HTTP coupling between microservices creates a tight dependency graph — if Service B is down, Service A fails immediately. RabbitMQ as a message bus decouples availability, but raw AMQP APIs are low-level and verbose. BugBunny gives you the ergonomics of a web framework on top of the reliability of a message broker.

---

## AMQP in 5 Minutes

AMQP (Advanced Message Queuing Protocol) is the protocol RabbitMQ implements. The key concepts:

**Exchange** — Receives messages from producers and routes them to queues based on rules. Types:
- `direct` — Routes to queues whose binding key exactly matches the routing key.
- `topic` — Routes using wildcard patterns (`orders.*`, `#.error`).
- `fanout` — Broadcasts to all bound queues regardless of routing key.

**Queue** — Stores messages until a consumer picks them up. Durable queues survive broker restarts.

**Routing Key** — A string the producer attaches to the message. The exchange uses it to decide which queues receive the message.

**Binding** — A link between an exchange and a queue, optionally with a routing key pattern.

In BugBunny, the **path** of the message (e.g., `nodes/123`) travels inside the AMQP `type` header. The routing key determines *which service* receives the message; the path determines *which controller and action* handles it inside that service.

---

## Architecture

```
Service A (Producer)
  BugBunny::Resource.find(id)
  BugBunny::Client#request(path)
        |
        v
  BugBunny::Producer
        |  publishes to exchange with:
        |    routing_key: 'nodes'
        |    type header: 'nodes/123'
        |    reply_to:    'amq.rabbitmq.reply-to'  (RPC only)
        |    correlation_id: 'abc-123'              (RPC only)
        v
   [ RabbitMQ Exchange ]
        |
        v
   [ RabbitMQ Queue ]
        |
        v
Service B (Consumer)
  BugBunny::Consumer (subscribe loop)
        |
        v
  ConsumerMiddleware::Stack
  (tracing, auth, etc.)
        |
        v
  Router (BugBunny.routes)
  matches 'GET nodes/123' → NodesController#show
        |
        v
  NodesController#show
  render status: :ok, json: node
        |
        v  (RPC only)
  reply → amq.rabbitmq.reply-to
        |
        v
Service A (unblocked)
  future.value → { body: {...}, headers: {...} }
```

---

## RPC vs Fire-and-Forget

BugBunny supports two communication patterns. Choosing the right one matters for system design.

### Synchronous RPC (`:rpc`)

The producer blocks until the consumer replies. Uses RabbitMQ's `amq.rabbitmq.reply-to` pseudo-queue — no temporary queues are created.

```ruby
response = client.request('users/42', method: :get)
# blocks here until the consumer sends back a reply (or timeout)
```

**Use when:** Service A needs the result to continue. Example: fetching user data before building a response, validating inventory before placing an order.

**Timeout:** Configurable via `config.rpc_timeout`. Raises `BugBunny::RequestTimeout` if the consumer does not reply in time.

**Cost:** Ties up a thread in Service A for the duration of the call.

### Fire-and-Forget (`:publish`)

The producer publishes and continues immediately. No reply is expected or waited for.

```ruby
client.publish('events', body: { type: 'order.placed', order_id: 99 })
# returns immediately with { 'status' => 202 }
```

**Use when:** Service A does not need a result. Example: emitting audit events, triggering background jobs, sending notifications.

**Cost:** None — but you have no confirmation that the message was processed successfully.

---

## Key Components

| Class | Role |
|---|---|
| `BugBunny::Configuration` | Global settings. Validates required fields on `BugBunny.configure`. |
| `BugBunny::Session` | Wraps a Bunny channel. Declares exchanges and queues. Thread-safe with double-checked locking. |
| `BugBunny::Producer` | Publishes messages. Implements RPC with `Concurrent::IVar`. |
| `BugBunny::Client` | High-level publisher API. Manages a connection pool and middleware stack. |
| `BugBunny::Consumer` | Subscribe loop. Routes messages to controllers via `BugBunny.routes`. |
| `BugBunny::ConsumerMiddleware::Stack` | Pipeline of middlewares executed before `process_message`. |
| `BugBunny::Controller` | Base class for message handlers. Supports `before_action`, `after_action`, `around_action`, `rescue_from`. |
| `BugBunny::Resource` | ActiveRecord-like ORM over AMQP. Provides `find`, `where`, `create`, `save`, `destroy`. |
| `BugBunny::Routing::RouteSet` | Stores and matches declared routes. |
| `BugBunny::Observability` | Mixin for structured logging. `safe_log` never raises. |

---

## Connection Pool

BugBunny uses the `connection_pool` gem to share connections safely across threads (Puma workers, Sidekiq threads).

```
ConnectionPool
  slot 0: Bunny::Session → BugBunny::Session → BugBunny::Producer
  slot 1: Bunny::Session → BugBunny::Session → BugBunny::Producer
  slot N: ...
```

Each pool slot caches its `Session` and `Producer` for the lifetime of the slot. This avoids re-creating AMQP channels (expensive) and prevents the double `basic_consume` error that would occur if a new Producer were created on a reused channel.

Thread safety is guaranteed by `ConnectionPool` itself: each slot is used by one thread at a time, so no additional mutex is needed at the Session or Producer level.
