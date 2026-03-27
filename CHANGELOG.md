# Changelog

## [4.5.0] - 2026-03-25

### ✨ New Features & DX
* **Controller Header API:** Se introdujo el método `headers` en `BugBunny::Controller` para permitir una manipulación intuitiva de las cabeceras de respuesta AMQP, siguiendo el patrón familiar de Rails.
    * Ejemplo: `headers['X-Custom'] = 'Value'`.
* **Observability Refinement:** Finalización de la migración al patrón de observabilidad estándar con nombres de eventos `clase.evento` en todos los componentes.

## [4.4.2] - 2026-03-25


### ✨ New Features
* **Request#params:** Se agregó el atributo `params` al objeto `Request` para enviar query params de forma declarativa, al estilo Faraday. Los params se serializan como query string (`Rack::Utils.build_nested_query`) y viajan en el header AMQP `type`, que es el que usa el consumer para rutear al controlador. La `routing_key` del exchange no se ve afectada.
* **Resource.where con params:** `Resource.where` ahora usa internamente `req.params` en lugar de construir la URL manualmente, unificando el comportamiento con el cliente directo.

### 🐛 Bug Fixes
* **Session#exchange:** El `name` y `type` del exchange se convierten a `String` via `.to_s` antes de pasarlos a Bunny, evitando `NoMethodError: undefined method 'gsub' for an instance of Symbol` al configurar exchanges con Symbols.
* **Configuration:** Se corrigió el namespace por defecto de controladores de `'Rabbit::Controllers'` a `'BugBunny::Controllers'`.

## [4.4.2] - 2026-03-25

### 📈 Observability & Standards Final Polish
* **Event Naming Standardization:** Se unificaron todos los nombres de eventos internos al formato estricto `clase.evento` (ej: `consumer.message_received`, `producer.rpc_waiting`) para una categorización impecable en motores de logs.
* **Encoding & Mojibake Cleanup:** Limpieza profunda de artefactos de codificación en comentarios y documentación de toda la gema, garantizando legibilidad total en español.
* **Internal Consistency:** Refactorización de llamadas a `safe_log` para utilizar metadatos simplificados y símbolos consistentes en todos los componentes clave.

## [4.4.1] - 2026-03-25

### 🐛 Bug Fixes
* **Producer:** Se corrigió el valor de retorno del método `fire` para que devuelva un Hash simbólico (`{ 'status' => 202 }`) en lugar del objeto Exchange. Esto previene errores de tipo `NoMethodError: undefined method []` en el cliente al realizar publicaciones asíncronas (`:publish`).

## [4.4.0] - 2026-03-24

### 📈 Standard Observability Pattern
* **Unified Observability Module:** Adopción del patrón de observabilidad estándar para todas las gemas.
* **Semantic Event Naming:** Todos los eventos ahora siguen el formato `clase.evento` (ej: `consumer.message_processed`, `producer.publish`) para una mejor categorización.
* **Resilient Logging:** Implementación de `@logger` en cada componente con el método `safe_log` para garantizar que la telemetría nunca interrumpa la ejecución principal.
* **Full Documentation Sync:** Actualización del README con los nuevos ejemplos de uso del patrón de observabilidad.

## [4.3.0] - 2026-03-24

### 📈 Observability Alignment (ExisRay Standards)
* **Monotonic Clock Durations:** Implementación de `Process.clock_gettime(Process::CLOCK_MONOTONIC)` para calcular todas las duraciones técnicas y de negocio (`duration_s`), garantizando precisión en entornos Cloud.
* **Unit-Suffix Keys (Data First):** Se renombraron las llaves de logs para incluir explícitamente su unidad:
    * `timeout` -> `timeout_s`
    * `retry_in` -> `retry_in_s`
    * `attempt` -> `attempt_count`
    * `max_attempts` -> `max_attempts_count`
* **Error Field Standardization:** Se renombraron todos los campos `error` a `error_message` para ser consistentes con los eventos de falla de `exis_ray`.
* **Automatic Field Removal:** Se eliminó la inyección manual de `source` delegando la responsabilidad a la gema `exis_ray`.

## [4.2.0] - 2026-03-22

### ðŸ”  Observability & Structured Logging
* **Structured Logs (Key-Value):** Se migraron todos los logs del framework a un formato \`key=value\` estructurado, ideal para herramientas de monitoreo como Datadog o CloudWatch. Se eliminaron emojis y texto libre para mejorar el parseo automÃ¡tico.
* **Lazy Evaluation (Debug Blocks):** Las llamadas a \`logger.debug\` ahora utilizan bloques para evitar la interpolaciÃ³n de strings innecesaria en producciÃ³n, optimizando el uso de CPU y memoria.

### ðŸ›¡ï¸  Resilience & Connectivity
* **Exponential Backoff:** El \`Consumer\` ahora implementa un algoritmo de reintento exponencial para reconectarse a RabbitMQ, evitando picos de carga durante caÃ­das del broker.
* **Max Reconnect Attempts:** Nueva configuraciÃ³n \`max_reconnect_attempts\` que permite que el worker falle definitivamente tras N intentos, facilitando el reinicio del Pod por parte de orquestadores como Kubernetes.
* **Performance Tuning:** Se desactivaron los \`publisher_confirms\` en el canal del \`Consumer\` al responder RPCs para reducir la latencia de respuesta (round-trips innecesarios).

## [4.1.2] - 2026-03-22

### ✨ Improvements
* **Controller:** Ahora lanza una excepciÃ³n \`BugBunny::BadRequest\` (400) si el cuerpo de la peticiÃ³n contiene un JSON invÃ¡lido, mejorando la depuraciÃ³n en el cliente.
* **Resource:** Se aÃ±adiÃ³ una protecciÃ³n a \`.with\` (\`ScopeProxy\`) para asegurar que el contexto sea de un solo uso, evitando efectos secundarios en llamadas encadenadas.

## [4.1.1] - 2026-03-22

### 🐛 Bug Fixes
* **Consumer:** Previene memory leak al detener el `TimerTask` de health check previo antes de realizar una reconexiÃ³n.
* **Controller:** Corrige la mutaciÃ³n accidental de \`log_tags\` globales al usar una lÃ³gica de herencia no destructiva en \`compute_tags\`.

## [4.1.0] - 2026-03-22

### 🚀 New Features & Improvements
* **Faraday-style Client API:** Se introdujo el mÃ©todo \`Client#send\` como punto de entrada genÃ©rico, permitiendo una sintaxis mÃ¡s familiar y flexible.
* **Flexible Delivery Modes:** IntroducciÃ³n del atributo \`delivery_mode\` (:rpc o :publish). Ahora es posible configurar la estrategia de envÃ­o a nivel de cliente o por cada peticiÃ³n individual.
* **Smart Request Defaults:** Los mÃ©todos \`request\` y \`publish\` ahora delegan internamente en \`send\`, manteniendo la compatibilidad pero beneficiÃ¡ndose de la nueva arquitectura de peticiones.

## [4.0.1] - 2026-03-13

### 🐛 Bug Fixes
* **Rails Autoload (Zeitwerk):** Corrige el registro de `app/rabbit` para autoload/eager load usando `app.config.paths.add` en lugar de mutar `autoload_paths`/`eager_load_paths`.

## [4.0.0] - 2026-03-02

### ⚠ Breaking Changes
* **Declarative Routing (Rails-style):** El enrutamiento "mágico" y heurístico del Consumer ha sido reemplazado por un motor de enrutamiento explícito y estricto.
  * Ahora es **obligatorio** definir un mapa de rutas usando el DSL `BugBunny.routes.draw` (típicamente en un inicializador como `config/initializers/bug_bunny_routes.rb`).
  * Los mensajes entrantes cuyas rutas no estén explícitamente declaradas serán rechazados inmediatamente con un error `404 Not Found`.

### 🚀 New Features & Architecture
* **Advanced Routing DSL:** Se construyó un motor de enrutamiento completo y robusto inspirado en `ActionDispatch::Routing` de Rails.
  * **Smart Route Parameters:** Compilación de rutas a expresiones regulares, permitiendo la extracción nativa de parámetros dinámicos desde la URL (ej. `get 'clusters/:cluster_id/nodes/:id/metrics'`). Estos se inyectan automáticamente en el hash `params` del Controlador.
  * **Resource Macros & Filtering:** Introducción del macro `resources :name` para generar endpoints CRUD estándar. Ahora soporta filtrado granular de acciones utilizando las opciones `only:` y `except:`.
  * **Nested Scopes (Member/Collection):** Soporte total para bloques anidados `member do ... end` y `collection do ... end` dentro de los recursos, permitiendo definir rutas complejas infiriendo automáticamente el controlador destino y la inyección del `:id`.

### 🛡️ Security & Observability
* **Strict Instantiation (RCE Prevention):** Al requerir que todas las rutas sean declaradas explícitamente por el desarrollador, se elimina por completo el vector de ataque que permitía intentar instanciar clases arbitrarias de Ruby manipulando el header `type`.
* **Enhanced Routing Logs:** El Consumer ahora emite un log de nivel `DEBUG` (marcado con 🎯) que confirma de manera transparente exactamente qué Controlador y Acción se resolvieron al evaluar la petición contra el mapa de rutas.

## [3.1.6] - 2026-02-27

### 🐛 Bug Fixes & Router Improvements
* **Enhanced Heuristic Router (ID Detection):** Mejoras críticas en `Consumer#router_dispatch` para soportar una gama mucho más amplia de formatos de identificadores y evitar colisiones con namespaces:
  * **Soporte para Swarm/NanoID:** Se amplió la expresión regular de detección de IDs para capturar hashes alfanuméricos de 20 o más caracteres (`[a-zA-Z0-9_-]{20,}`), permitiendo el correcto ruteo de IDs generados por Docker Swarm (25 caracteres) o NanoID.
  * **Escaneo Inverso (Right-to-Left):** Se modificó la búsqueda del ID para que escanee los segmentos de la URL desde el final hacia el principio (`rindex`). Esto evita falsos positivos donde namespaces cortos como `v1` (ej. `api/v1/...`) eran confundidos accidentalmente con un ID.
  * **Fallback Semántico Posicional:** Se introdujo una red de seguridad (fallback) que infiere la posición del ID basándose en el Verbo HTTP. Si el ID no coincide con ningún patrón Regex (ej. es un ID corto como `node-1`), pero el método es `PUT`, `PATCH` o `DELETE`, el enrutador ahora asume inteligentemente que el penúltimo/último segmento corresponde al ID del recurso.

## [3.1.5] - 2026-02-25

### ✨ New Features & Improvements
* **Smart Heuristic Router (Namespace Support):** El enrutador interno del consumidor (`Consumer#router_dispatch`) fue reescrito para soportar namespaces profundos y rutas anidadas sin necesidad de configuración manual. Utiliza una heurística basada en Regex para detectar dinámicamente identificadores (Enteros, UUIDs o hashes alfanuméricos largos) dentro de la URL.
  * Esto permite que rutas complejas como `GET api/v1/ecommerce/orders/a1b2c3d4/cancel` resuelvan automáticamente al controlador `Api::V1::Ecommerce::OrdersController`, asignando `id: a1b2c3d4` y `action: cancel`.

## [3.1.4] - 2026-02-21

### 🚀 Cloud Native & Infrastructure Features
* **Docker Swarm / Kubernetes Health Checks:** Introduced native support for external orchestrator health checks using the **Touchfile** pattern.
  * Added `config.health_check_file` to the global configuration.
  * The `Consumer`'s internal heartbeat now automatically updates the modification time (`touch`) of the specified file upon successful validation of the RabbitMQ connection and queue existence.
  * Fails gracefully without interrupting the consumer if file system permissions are restricted.

### 📖 Documentation
* **Production Guide Expansion:** Added a comprehensive "Health Checks en Docker Swarm / Kubernetes" section to the README. Includes detailed `docker-compose.yml` examples demonstrating best practices for integrating the touchfile pattern, specifically highlighting the critical use of `start_period` to accommodate Rails boot times.

## [3.1.3] - 2026-02-19

### 🏗️ Architectural Refactoring (Middleware Standardization)
* **Centralized Error Handling:** Refactored `BugBunny::Resource` to completely delegate HTTP status evaluation to the `RaiseError` middleware. The ORM now operates strictly on a "Happy Path" mentality, rescuing semantic exceptions (`NotFound`, `UnprocessableEntity`) natively.
* **Middleware Injection Enforcement:** `BugBunny::Resource` now explicitly guarantees that `BugBunny::Middleware::RaiseError` and `BugBunny::Middleware::JsonResponse` are the core of the stack, ensuring consistent data parsing and error raising before any custom user middlewares are executed.

### ✨ New Features & Improvements
* **Smart Validation Errors:** `BugBunny::UnprocessableEntity` (422) is now intelligent. It automatically parses the remote worker's response payload, gracefully handling string fallbacks or extracting the standard Rails `{ errors: ... }` convention to accurately populate local object validations.
* **HTTP 409 Conflict Support:** Added native support for `409 Conflict` mapping it to the new `BugBunny::Conflict` exception. Ideal for handling state collisions in distributed systems.
* **Global Error Formatting:** Moved `format_error_message` directly into the `RaiseError` middleware. Now, even manual `BugBunny::Client` requests will benefit from clean, structured exception messages (e.g., `"Internal Server Error - undefined method"`) optimized for APMs like Sentry or Datadog.

## [3.1.2] - 2026-02-19

### 🐛 Bug Fixes
* **Controller Callback Inheritance:** Fixed a critical issue where `before_action`, `around_action`, and `rescue_from` definitions in a parent class (like `ApplicationController`) were not being inherited by child controllers. Migrated internal storage to `class_attribute` with deep duplication to ensure isolated, thread-safe inheritance without mutating the parent class.
* **Gemspec Hygiene:** Updated the `spec.description` to resolve RubyGems identity warnings and added explicit minimum version boundaries for standard dependencies (e.g., `json >= 2.0`).

### 🌟 Observability & DX (Developer Experience)
* **Structured Remote Errors:** `BugBunny::Resource` now intelligently formats the body of remote errors. When raising a `ClientError` (4xx) or `InternalServerError` (500), it extracts the specific error message (e.g., `"Internal Server Error - undefined method 'foo'"`) or falls back to a readable JSON string. This drastically improves the legibility of remote stack traces in monitoring tools like Sentry or Datadog.
* **Infrastructure Logging:** The `Consumer` and `Producer` now calculate the final resolved cascade options (`exchange_opts`, `queue_opts`) and explicitly log them during worker startup and message publishing. This provides absolute transparency into what configurations are actually reaching RabbitMQ.
* **Consumer Cascade Options:** Added the `exchange_opts:` parameter to `Consumer.subscribe` to fully support Level 3 (On-the-fly) infrastructure configuration for manual worker instantiations.

### 📖 Documentation
* **Built-in Middlewares:** Added comprehensive documentation to the README explaining how to inject and utilize the provided `RaiseError` and `JsonResponse` middlewares when using the manual `BugBunny::Client`.

## [3.1.1] - 2026-02-19

### 🚀 Features
* **Infrastructure Configuration Cascade:** Added support for dynamic configuration of RabbitMQ Exchanges and Queues (e.g., `durable`, `auto_delete`). Configurations can now be applied across 3 levels:
  1. **Global Default:** Via `BugBunny.configure { |c| c.exchange_options = {...} }`.
  2. **Resource Level:** Via class attributes `self.exchange_options = {...}` on `BugBunny::Resource`.
  3. **On-the-fly:** Via `BugBunny::Client` request kwargs or `Resource.with(exchange_options: {...})`.

### 🛠 Improvements
* **Test Suite Resilience:** Updated internal test helpers to use global cascade configurations, resolving `PRECONDITION_FAILED` conflicts during rapid test execution.

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
