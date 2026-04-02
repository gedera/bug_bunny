## Glossary

**AMQP** — Advanced Message Queuing Protocol. The binary wire protocol used by RabbitMQ. BugBunny uses Bunny as its AMQP client.

**Exchange** — A RabbitMQ routing point. Publishers send messages to exchanges; exchanges route them to queues based on bindings and routing keys. BugBunny supports `direct`, `topic`, and `fanout` types.

**Queue** — A buffer that holds messages until they are consumed. A queue is bound to an exchange with a routing key pattern.

**Routing key** — A string label attached to a published message. The exchange uses it to decide which queues receive the message. In BugBunny, the routing key defaults to the pluralized resource name (e.g., `users`).

**Binding** — The link between an exchange and a queue, specifying which routing key patterns match.

**Session** — `BugBunny::Session`. A wrapper around a Bunny channel. Declares exchanges and queues, caches their AMQP objects, and handles double-checked locking for thread safety.

**Producer** — `BugBunny::Producer`. Publishes messages to RabbitMQ. Implements both RPC (blocking) and fire-and-forget (non-blocking) modes. One Producer is cached per connection slot.

**Consumer** — `BugBunny::Consumer`. The subscribe loop that runs in a worker process. Receives messages, routes them through middleware and the router, dispatches to a controller, and sends RPC replies.

**RPC (Remote Procedure Call)** — A synchronous request-response pattern over RabbitMQ. The producer publishes with `reply_to: 'amq.rabbitmq.reply-to'` and blocks on a `Concurrent::IVar` until the consumer replies to that pseudo-queue.

**Fire-and-forget** — An asynchronous publish with no reply expected. The producer does not block. Used for events, notifications, and side effects.

**Direct Reply-to** — A RabbitMQ pseudo-queue (`amq.rabbitmq.reply-to`) that allows RPC replies without declaring a temporary queue. BugBunny uses this for all RPC responses.

**Controller** — `BugBunny::Controller`. A class that handles an incoming routed message. Mirrors Rails ActionController: supports `before_action`, `around_action`, `after_action`, `rescue_from`, `params`, and `render`.

**Resource** — `BugBunny::Resource`. An ActiveRecord-like ORM over AMQP. Wraps CRUD operations as RPC calls. Used by the publishing side to interact with a remote service.

**Client** — `BugBunny::Client`. High-level API for the publisher side. Implements the Onion Middleware (Faraday-style) pattern around the Producer.

**ConsumerMiddleware** — A pipeline of middleware objects that runs before each message is dispatched to a controller. Used for cross-cutting concerns: tracing, authentication, logging.

**ConnectionPool** — A `connection_pool` gem pool of Bunny connections. Each slot holds one connection, one Session, and one Producer. `Resource.connection_pool` must be set before making AMQP calls.

**IVar (Ivar / Concurrent::IVar)** — An immutable variable from the `concurrent-ruby` gem. Used to block the calling thread until the RPC reply arrives or the timeout expires.

**health_check_file** — A file path that BugBunny touches periodically (every `health_check_interval` seconds) after verifying the RabbitMQ connection. Used as a liveness probe in Docker/Kubernetes.

**rpc_reply_headers** — A `Proc` returning a `Hash` of AMQP headers injected into every RPC reply. Used to propagate trace context from consumer back to producer.

**on_rpc_reply** — A `Proc` called on the producer's thread when an RPC reply arrives, with the reply's AMQP headers. Used to hydrate trace context in the calling service.

**Namespace routing** — A DSL feature that prefixes a group of routes with a module namespace and a path prefix. Example: `namespace :admin` generates routes under `Admin::Controllers::*Controller` with path prefix `admin/`.

**param_key** — The root key used to wrap the payload in POST/PUT requests. Defaults to the singularized resource name (e.g., `user` for `UsersResource`).
