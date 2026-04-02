## FAQ — Internal (Maintainer / Developer of BugBunny)

### Why is Producer cached per connection slot instead of instantiated per request?

`Producer#initialize` calls `channel.basic_consume` on the `amq.rabbitmq.reply-to` pseudo-queue to listen for RPC replies. Creating a second `basic_consume` on the same channel raises an AMQP error. Therefore, one Producer per channel (= per connection slot) is mandatory. The cache is stored as `@_bug_bunny_producer` ivar on the Bunny connection object, which is safe because `ConnectionPool` guarantees each slot is used by one thread at a time.

---

### Why is Session cached per connection slot?

Same reason as Producer — and the Session wraps the channel. Recreating a Session would create a new channel and invalidate the cached exchange/queue objects. Caching is stored as `@_bug_bunny_session` on the Bunny connection object.

---

### How does the Session handle thread safety for exchange/queue declarations?

Session uses a double-checked locking pattern with a `Mutex` for its caches (`@exchange_cache`, `@queue_cache`). The read path (fast path) checks without locking; the write path acquires the mutex and checks again before writing. This avoids redundant AMQP declarations without making every read a mutex acquisition.

---

### Why does Resource have two dirty tracking mechanisms?

ActiveModel::Dirty only tracks attributes declared with `attribute :name, :type`. BugBunny Resources allow dynamic attributes (unknown at class definition time) stored in `@extra_attributes`. These are tracked manually via `@dynamic_changes` (a `Set`). The `changed?` and `changed` methods merge both to produce a unified change list.

---

### How does the 3-level config cascade work in Resource?

`resolve_config(key, instance_var)` checks in order:
1. `Thread.current["bb_#{object_id}_#{key}"]` — set by `.with(...)`.
2. `self.instance_variable_get(instance_var)` — class-level static config.
3. Walk `superclass` chain up to (but not including) `BugBunny::Resource`.

This means a subclass can override the parent's config, and `.with` overrides everything for the duration of its block.

---

### How does ConsumerMiddleware::Stack protect against concurrent registration?

`Stack#use` wraps the append in a `@mutex.synchronize` block. The execution path (`call`) does not use the mutex — it reads `@middlewares` once at call time (snapshot). This is safe because Rails/Zeitwerk loads middleware registrations at boot, before any concurrent requests.

---

### How does routing with namespaces work internally?

`namespace :admin { resources :users }` generates `Route` objects with:
- `path_prefix: 'admin'` — prepended to the path pattern.
- `namespace: 'Admin::Controllers'` — overrides the default namespace for `constantize`.

In `process_message`, the Consumer resolves `base_namespace = route_info[:namespace] || config.controller_namespace` before calling `constantize`.

---

### What is the RCE prevention in the Consumer?

After `constantize`, the Consumer checks `controller_class < BugBunny::Controller`. This prevents an attacker from crafting a message with a `type` header pointing to an arbitrary Ruby class (e.g., `Kernel` or `File`) and triggering its methods. Any class not inheriting from `BugBunny::Controller` gets a 403 reply and the message is rejected.

---

### How does `before_action` halt chain propagation?

`run_before_actions` iterates before-actions and calls each. After each call, it checks `rendered_response`. If a filter called `render(...)`, `@rendered_response` is set. The method returns `false`, and `core_execution` skips the action and `after_actions`. After-actions do not run if the before-action chain was halted.

---

### How does `after_action` differ from `around_action`?

`after_action` runs after the action method returns, but only if no `before_action` halted the chain and no exception was raised. `around_action` wraps the entire execution including before/after actions and is responsible for yielding. Use `around_action` when you need cleanup regardless of exceptions.

---

### How does `safe_log` prevent log failures from affecting main flow?

`safe_log` wraps every logger call in `rescue StandardError`. It also filters sensitive keys by checking if the key string matches a predefined set of patterns (`password`, `pass`, `passwd`, `secret`, `token`, `api_key`, `auth`) before emitting values. Blocks are always passed to `logger.debug` to avoid string interpolation cost at non-debug levels.

---

### How is the Consumer health check implemented?

`start_health_check` creates a `Concurrent::TimerTask` that runs every `health_check_interval` seconds. Each tick calls `channel.queue_declare(queue_name, passive: true)` — a passive declare that verifies the queue exists without creating it. On failure, it calls `session.close`, which triggers the reconnect loop in `subscribe`. The health file is touched on success.

---

### What triggers the reconnect loop in Consumer?

Any `StandardError` raised inside the `subscribe` rescue block. The loop uses exponential backoff: `wait = [interval * 2^(attempt-1), max_interval].min`. If `max_reconnect_attempts` is set and exceeded, the error is re-raised, killing the process.
