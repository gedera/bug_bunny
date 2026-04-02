## Errors

All BugBunny exceptions inherit from `BugBunny::Error < StandardError`. Catch `BugBunny::Error` to handle all gem-level errors.

---

### BugBunny::ConfigurationError

**Cause:** `BugBunny.configure` block completed with invalid values. Triggered by `validate!` at the end of `configure`.

**Common triggers:**
- `host` is nil or empty string
- `port` is outside `1..65535`
- `rpc_timeout` is not an Integer or is outside `1..3600`

**How to reproduce:**
```ruby
BugBunny.configure { |c| c.host = '' }
# => BugBunny::ConfigurationError: host is required
```

**Resolution:** Check all required fields. See `Configuration::VALIDATIONS` for the full list of validated attributes and their constraints.

---

### BugBunny::CommunicationError

**Cause:** TCP-level failure connecting to or communicating with RabbitMQ. Usually wraps a Bunny internal exception.

**Common triggers:**
- RabbitMQ is not running
- Wrong host/port
- Firewall blocking the connection
- Network interruption during message exchange

**Resolution:** Check RabbitMQ is reachable (`telnet host 5672`). Review `network_recovery_interval` and `max_reconnect_attempts` settings. The Consumer retries automatically with exponential backoff.

---

### BugBunny::SecurityError

**Cause:** The Consumer received a message with a `type` header that resolves to a class not inheriting from `BugBunny::Controller`.

**How to reproduce:**
```ruby
# Publish a message with type: "Kernel"
```

**Resolution:** This is an intentional RCE prevention check. Ensure all controller classes inherit from `BugBunny::Controller`. If legitimate, verify `config.controller_namespace` is set correctly.

---

### BugBunny::RequestTimeout

**Cause:** An RPC call did not receive a reply within `config.rpc_timeout` seconds.

**Common triggers:**
- The Consumer is not running
- The Consumer is overwhelmed (increase `channel_prefetch`)
- `rpc_timeout` is too low for the workload
- The remote controller raised an exception before sending a reply (check consumer logs)

**Resolution:** Check that the Consumer process is alive. Review `consumer.execution_error` log entries on the consumer side. Increase `rpc_timeout` if the operation is legitimately slow.

---

### BugBunny::NotFound (404)

**Cause:** The remote service responded with HTTP 404. Raised by `Middleware::RaiseError`.

**In Resource context:** `find` and `where` catch this internally and return `nil` / `[]` respectively.

**In Client context:** Propagates unless caught by the caller.

**Resolution:** Verify the resource ID exists. Ensure the Consumer's route for that path is registered.

---

### BugBunny::BadRequest (400)

**Cause:** The remote service returned 400. Also raised locally if the JSON body cannot be parsed.

**Local trigger:**
```ruby
# In Controller#prepare_params — body is not valid JSON and content_type includes 'json'
```

**Resolution:** Verify the request body is valid JSON when `content_type: 'application/json'` is used.

---

### BugBunny::Conflict (409)

**Cause:** The remote service returned 409 — the request is technically valid but conflicts with business rules or existing data.

**Resolution:** Handle the conflict in application logic. Inspect `e.message` for details from the remote service.

---

### BugBunny::UnprocessableEntity (422)

**Cause:** The remote service returned 422 (validation failure).

**Attributes:**
- `e.error_messages` — `Hash`, `Array`, or `String` extracted from `{ "errors": ... }` in the response body.
- `e.raw_response` — The raw response body.

**In Resource context:** `save` catches this, loads errors into `resource.errors`, and returns `false`.

**In Client context:** Raised directly.

**Resolution:**
```ruby
resource = Order.create(attrs)
unless resource.persisted?
  resource.errors.full_messages  # => ["Status can't be blank"]
end
```

---

### BugBunny::NotAcceptable (406)

**Cause:** The remote service returned 406 — it cannot produce a response matching the requested content type.

**Resolution:** Ensure the client and server agree on content type. BugBunny uses `application/json` by default.

---

### BugBunny::InternalServerError (500)

**Cause:** The remote service returned 500. Also sent by the Consumer when an unhandled exception occurs during `process_message`.

**Resolution:** Check `consumer.execution_error` log entries on the consumer side for the actual exception. Fix the underlying error in the controller.

---

### BugBunny::Error: "Connection pool missing for ClassName"

**Cause:** `Resource.bug_bunny_client` was called before `Resource.connection_pool` was set.

**Resolution:** Set `BugBunny::Resource.connection_pool = MY_POOL` in the initializer before any Resource calls.

---

### BugBunny::Error: "ScopeProxy is single-use"

**Cause:** A `ScopeProxy` returned by `.with(...)` without a block was called more than once.

**Resolution:** Use the block form: `Resource.with(...) { ... }` or call `.with(...)` again for each subsequent call.

---

### BugBunny::Error: "Exchange not defined for ClassName"

**Cause:** `Resource.current_exchange` was called but no exchange was configured at any level (thread-local, class, or superclass).

**Resolution:** Set `self.exchange = 'exchange_name'` in the Resource class definition or use `.with(exchange:)`.
