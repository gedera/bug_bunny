# Changelog
## [3.1.0] - 2026-02-18

### 🌟 New Features: Observability & Tracing
* **Distributed Tracing Stack:** Implemented a native distributed tracing system that ensures full visibility from the Producer to the Consumer/Worker.
    * **Producer:** Messages now automatically carry a `correlation_id`. Added support for custom Middlewares to inject IDs from the application context (e.g., Rails `Current.request_id` or Sidekiq IDs).
    * **Consumer:** Automatically extracts the `correlation_id` from AMQP headers and wraps the entire execution in a **Tagged Logger** block (e.g., `[d41d8cd9...] [API] Processing...`).
    * **Controller:** Introduced `self.log_tags` to allow injecting rich business context into logs (e.g., `[Tenant-123]`) using the native `around_action` hook.

### 🛡 Security
* **Router Hardening:** Added a strict inheritance check in the `Consumer`.
    * **Prevention:** The router now verifies that the instantiated class inherits from `BugBunny::Controller` before execution.
    * **Impact:** Prevents potential **Remote Code Execution (RCE)** vulnerabilities where an attacker could try to instantiate arbitrary system classes (like `::Kernel`) via the `type` header.

### 🐛 Bug Fixes
* **RPC Type Consistency:** Fixed a critical issue where RPC responses were ignored if the `correlation_id` was an Integer.
    * **Fix:** The Producer now strictly normalizes all correlation IDs to Strings (`.to_s`) during both storage (pending requests) and retrieval (reply listener), ensuring reliable matching regardless of the ID format.

## [3.0.6] - 2026-02-17

### ♻️ Refactor & Standards
* **Architectural Cleanup:** Removed the `BugBunny::Rabbit` intermediate class. Connection management logic (`disconnect`) has been moved directly to the main `BugBunny` module for simplicity.
* **Rails Standardization:** Renamed `lib/bug_bunny/config.rb` to `lib/bug_bunny/configuration.rb` and the class from `Config` to `Configuration`. This ensures full compliance with Zeitwerk autoloading standards.

### 🛡 Stability
* **Fork Safety:** Enhanced `Railtie` to robustly handle process forking. Added support for `ActiveSupport::ForkTracker` (Rails 7.1+) and guarded Puma event hooks to prevent `NoMethodError` on newer Puma versions.

## [3.0.5] - 2026-02-17

### 🐛 Bug Fixes
* **Load Error Resolution:** Fixed `TypeError: Middleware is not a module` by converting `BugBunny::Middleware` into a proper module and introducing `BugBunny::Middleware::Base`.

### 🛠 Improvements
* **Standardized Middleware Architecture:** Consolidated the Template Method pattern across all internal interceptors (`RaiseError`, `JsonResponse`).

## [3.0.4] - 2026-02-16

### ♻️ Refactoring & Architecture
* **Middleware Architecture Overhaul:** Refactored the internal middleware stack to follow the **Template Method** pattern (Faraday-style).
    * **New Base Class:** Introduced `BugBunny::Middleware` to standardize the execution flow (`call`, `app.call`).
    * **Lifecycle Hooks:** Middlewares can now simply implement `on_request(env)` and/or `on_complete(response)` methods, eliminating the need to manually manage the execution chain.
    * **Core Middlewares:** Refactored `RaiseError` and `JsonResponse` to use this new pattern, resulting in cleaner and more maintainable code.
    * This change is **fully backward compatible** and paves the way for future middlewares (Loggers, Tracing, Headers injection).

## [3.0.3] - 2026-02-13

### 🐛 Bug Fixes
* **Nested Query Serialization:** Fixed an issue where passing nested hashes to `Resource.where` (e.g., `where(q: { service: 'rabbit' })`) produced invalid URL strings (Ruby's `to_s` format) instead of standard HTTP query parameters.
    * **Resource:** Now uses `Rack::Utils.build_nested_query` to generate correct URLs (e.g., `?q[service]=rabbit`).
    * **Consumer:** Now uses `Rack::Utils.parse_nested_query` to correctly reconstruct nested hashes from the query string.

## [3.0.2] - 2026-02-12

### 🚀 Features
* **Automatic Parameter Wrapping:** `BugBunny::Resource` now automatically wraps the payload inside a root key derived from the model name (e.g., `Manager::Service` -> `{ service: { ... } }`). This mimics Rails form behavior and enables the use of `params.require(:service)` in controllers.
    * Added `self.param_key = '...'` to `BugBunny::Resource` to allow custom root keys.
* **Declarative Error Handling:** Added Rails-like `rescue_from` DSL to `BugBunny::Controller`. You can now register exception handlers at the class level without overriding methods manually.
    ```ruby
    rescue_from ActiveRecord::RecordNotFound do |e|
      render status: :not_found, json: { error: e.message }
    end
    ```

### 🐛 Bug Fixes
* **RPC Timeouts on Crash:** Fixed a critical issue where the Client would hang until timeout (`BugBunny::RequestTimeout`) if the Consumer crashed or the route was not found.
    * The Consumer now catches `NameError` (Route not found) and returns a **501 Not Implemented**.
    * The Consumer catches unhandled `StandardError` (App crash) and returns a **500 Internal Server Error**.
    * Ensures a reply is ALWAYS sent to the caller, preventing blocking processes.

### 🛠 Improvements
* **Controller:** Refactored `BugBunny::Controller` to include a default safety net that catches unhandled errors and logs them properly before returning a 500 status.

## [3.0.1] - 2026-02-10

### 🚀 Features: RESTful Architecture
* **HTTP Verbs over AMQP:** Implemented support for semantic HTTP verbs (`GET`, `POST`, `PUT`, `DELETE`) within AMQP headers (`x-http-method`). This enables a true RESTful design over RabbitMQ.
* **Smart Router:** The `BugBunny::Consumer` now behaves like a Rails Router. It automatically infers the controller action based on the combination of the **Verb** and the **URL Path** (e.g., `GET users/1` dispatches to `show`, `POST users` to `create`).
* **Resource CRUD Mapping:** `BugBunny::Resource` now maps Ruby operations to their specific REST verbs:
    * `create` -> `POST`
    * `update` -> `PUT`
    * `destroy` -> `DELETE`
    * `find/where` -> `GET`.

### 🛠 Improvements
* **Client API:** Updated `BugBunny::Client#request` and `#publish` to accept a `method:` argument (e.g., `client.request('users', method: :post)`), giving developers full control over the request semantics without changing the method signature.
* **Request Metadata:** `BugBunny::Request` now handles the `method` attribute and ensures it is properly injected into the AMQP headers for the consumer to read.

## [3.0.0] - 2026-02-05

### ⚠ Breaking Changes
* **Architecture Overhaul:** Complete rewrite implementing the "Active Record over AMQP" philosophy. The framework now simulates a RESTful architecture where messages contain "URLs" (via `type` header) that map to Controllers.
* **Resource Configuration:** Removed `routing_key_prefix` in favor of `resource_name`. By default, `resource_name` is now automatically pluralized (Rails-style) to determine routing keys and headers.
* **Schema-less Resources:** Removed strict `ActiveModel::Attributes` dependency. `BugBunny::Resource` no longer requires defining attributes manually. It now uses a dynamic storage (`@remote_attributes`) supporting arbitrary keys (including PascalCase for Docker APIs) via `method_missing`.

### 🚀 New Features
* **Middleware Stack:** Implemented an "Onion Architecture" for the `Client` similar to Faraday. Added support for middleware chains to intercept requests/responses.
    * `Middleware::JsonResponse`: Automatically parses JSON bodies and provides `IndifferentAccess`.
    * `Middleware::RaiseError`: Maps AMQP/HTTP status codes to Ruby exceptions (e.g., 404 to `BugBunny::NotFound`).
* **REST-over-AMQP Routing:** The `Consumer` now parses the `type` header as a URL (e.g., `users/show/12?active=true`) to dispatch actions to specific Controllers.
* **Direct Reply-To RPC:** Optimized RPC calls to use RabbitMQ's native `amq.rabbitmq.reply-to` feature, eliminating the need for temporary reply queues and improving performance.
* **Config Inheritance:** `BugBunny::Resource` configurations (like `connection_pool`, `exchange`) are now inherited by child classes, simplifying setup for groups of models.

### 🛠 Improvements
* **Connection Pooling:** Full integration with `connection_pool` to ensure thread safety in multi-threaded environments (Puma/Sidekiq).
* **Error Handling:** Unified exception hierarchy under `BugBunny::Error`, with specific classes for Client (4xx) and Server (5xx) errors.
* **Rails Integration:** Added `Railtie` with hooks for Puma and Spring to safely handle connection forks.
* **Documentation:** Added comprehensive YARD documentation for all core classes.

## Version 0.1.0
* Migration bunny logic from utils
