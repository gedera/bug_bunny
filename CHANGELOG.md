# Changelog

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
