# BugBunny Expert

Skill de conocimiento completo sobre BugBunny. Consultame para cualquier pregunta sobre integración, arquitectura, API, errores y antipatrones.

---

## Glosario

**AMQP** — Advanced Message Queuing Protocol. Protocolo binario que implementa RabbitMQ.
**Bunny** — Cliente Ruby para AMQP. BugBunny lo usa internamente para conexiones, canales y publicación.
**Exchange** — Recibe mensajes del producer y los enruta a queues según reglas. Tipos: `direct` (match exacto), `topic` (wildcards), `fanout` (broadcast).
**Queue** — Almacena mensajes hasta que un consumer los consume. Las queues durables sobreviven reinicios del broker.
**Routing Key** — String que el producer adjunta al mensaje. El exchange lo usa para decidir a qué queues enrutar.
**Binding** — Enlace entre un exchange y una queue, opcionalmente con un patrón de routing key.
**Session** — `BugBunny::Session` envuelve canales de Bunny con thread-safety y double-checked locking.
**RPC** — Patrón síncrono que usa la pseudo-cola `amq.rabbitmq.reply-to` para respuestas sin crear queues temporales.
**Fire-and-Forget** — Patrón asíncrono donde el producer publica y continúa sin esperar respuesta. Retorna `{ 'status' => 202 }`.
**Resource** — ORM tipo ActiveRecord que mapea operaciones CRUD a llamadas AMQP.
**Consumer** — Worker bloqueante que despacha mensajes a controladores mediante un Router.
**Connection Pool** — Pool de conexiones (`connection_pool` gem) que comparte sessions entre threads. Cada slot cachea su `Session` y `Producer`.

---

## Arquitectura: Flujo RPC

```
┌──────────┐     ┌──────────┐     ┌──────────┐     ┌──────────┐
│ Resource  │────>│  Client  │────>│ Middleware│────>│ Producer │
└──────────┘     └──────────┘     │  Stack   │     └────┬─────┘
                                  └──────────┘          │
                                                        ▼
                                                  ┌──────────┐
                                                  │ Exchange  │
                                                  └────┬─────┘
                                                       │
                                                       ▼
                                                  ┌──────────┐
                                                  │  Queue   │
                                                  └────┬─────┘
                                                       │
                                                       ▼
┌──────────┐     ┌──────────┐     ┌──────────┐     ┌──────────┐
│  Reply   │<────│Controller│<────│  Router  │<────│ Consumer │
└──────────┘     └──────────┘     └──────────┘     └──────────┘
```

1. El `Client` pasa la petición por una pila de middlewares client-side.
2. El `Producer` publica en el exchange con `correlation_id`, `reply_to` y el path en el header `type`.
3. El hilo emisor se bloquea en un `Concurrent::IVar` esperando la respuesta.
4. El `Consumer` recibe, ejecuta consumer middlewares, rutea al controller.
5. El controller ejecuta callbacks y la acción, luego responde via `reply_to`.
6. Se aplican ganchos de traza (`on_rpc_reply`) y se devuelve el objeto hidratado.

---

## Arquitectura: Componentes Clave

| Clase | Responsabilidad |
|---|---|
| `BugBunny::Configuration` | Configuración global. Valida campos requeridos en `BugBunny.configure`. |
| `BugBunny::Session` | Wrapper de canal Bunny. Declara exchanges y queues. Thread-safe con double-checked locking. |
| `BugBunny::Producer` | Publica mensajes. Implementa RPC con `Concurrent::IVar` y direct reply-to. |
| `BugBunny::Client` | API de alto nivel. Pool de conexiones y middleware stack (onion architecture). |
| `BugBunny::Consumer` | Subscribe loop con health check. Rutea mensajes via `BugBunny.routes`. |
| `BugBunny::ConsumerMiddleware::Stack` | Pipeline de middlewares antes de `process_message`. Thread-safe. |
| `BugBunny::Controller` | Base class tipo Rails. `before_action`, `around_action`, `after_action`, `rescue_from`, `render`. |
| `BugBunny::Resource` | ORM sobre AMQP. `find`, `where`, `create`, `save`, `destroy`. ActiveModel validations y callbacks. |
| `BugBunny::Routing::RouteSet` | DSL de rutas: `resources`, `namespace`, `member`, `collection`. |
| `BugBunny::Observability` | Mixin de logging estructurado. `safe_log` nunca lanza excepciones. Filtra keys sensibles. |
| `BugBunny::Middleware::Stack` | Builder de middlewares client-side (onion architecture tipo Faraday). |
| BugBunny::Request | Value object del mensaje saliente con metadata AMQP completa. |
| BugBunny::OTel | Helpers para emitir campos siguiendo las OTel semantic conventions for messaging. |
| BugBunny::Railtie | Integración Rails: autoload de `app/rabbit`, fork safety (Puma, Spring). |

---

## Observability: OpenTelemetry

BugBunny implementa las [OpenTelemetry semantic conventions for messaging](https://opentelemetry.io/docs/specs/otel/trace/semantic-conventions/messaging/) de forma nativa para garantizar la trazabilidad entre servicios en entornos distribuidos.

### Campos Estándar (Flat-naming)

| Campo | Valor / Origen | Propósito |
|---|---|---|
| `messaging_system` | `"rabbitmq"` | Identifica el broker. |
| `messaging_operation` | `"publish"`, `"receive"`, `"process"` | Tipo de interacción. |
| `messaging_destination_name` | `exchange_name` | Exchange destino (o `""` para default). |
| `messaging_routing_key` | `routing_key` | Clave de ruteo final. |
| `messaging_message_id` | `correlation_id` | ID único para correlación y traza. |

### Inyección y Extracción

- **Publisher:** Inyecta estos campos en los headers AMQP bajo el prefijo `messaging_`. El usuario puede sobrescribirlos como *escape hatch* desde `headers`.
- **Consumer:** Extrae los campos de los logs estructurados sin mutar los headers originales. Los eventos `consumer.message_received` y `consumer.message_processed` incluyen estos campos automáticamente.
- **RPC Reply:** El consumer inyecta los mismos campos en el reply para cerrar el ciclo de traza del lado del cliente.

---

## API: Configuración Global

```ruby
BugBunny.configure do |config|
  # Conexión
  config.host = 'localhost'          # default: '127.0.0.1'
  config.port = 5672                 # default: 5672
  config.username = 'guest'          # default: 'guest'
  config.password = 'guest'          # default: 'guest'
  config.vhost = '/'                 # default: '/'

  # Resiliencia
  config.automatically_recover = true
  config.network_recovery_interval = 5
  config.max_reconnect_attempts = nil  # nil = infinito
  config.connection_timeout = 10
  config.heartbeat = 15

  # Performance
  config.channel_prefetch = 1
  config.rpc_timeout = 10

  # Logging
  config.logger = Rails.logger
  config.log_tags = [:uuid]

  # Propagación de trazas
  config.rpc_reply_headers = -> { { 'X-Trace-Id' => Tracer.id } }
  config.on_rpc_reply = ->(h) { Tracer.hydrate(h['X-Trace-Id']) }

  # Infraestructura (cascade level 2)
  config.exchange_options = { durable: true }
  config.queue_options = { auto_delete: false }

  # Health check
  config.health_check_interval = 60
  config.health_check_file = 'tmp/bb_health'

  # Routing
  config.controller_namespace = 'BugBunny::Controllers'
end
```

La validación es automática tras el bloque; lanza `ConfigurationError` si faltan campos requeridos o los valores están fuera de rango.

---

## API: Routing DSL

```ruby
BugBunny.routes.draw do
  resources :users
  resources :orders, only: [:index, :show]
  resources :products, except: [:destroy]

  namespace :admin do
    resources :reports
    resources :nodes do
      member do
        put :drain           # PUT nodes/:id/drain
      end
      collection do
        get :stats           # GET nodes/stats
      end
    end
  end
end
```

Genera rutas REST estándar (index, show, create, update, destroy) mapeadas a controladores. El `namespace` añade prefijo al path y busca controladores dentro del módulo correspondiente.

---

## API: RPC vs Fire-and-Forget

**RPC síncrono** — Bloquea hasta respuesta. Usa `amq.rabbitmq.reply-to`. Timeout configurable.
```ruby
response = client.request('users/42', method: :get)
# → { 'status' => 200, 'body' => { 'id' => 42, 'name' => 'John' } }
```

**Fire-and-Forget** — Publica y continúa. Sin confirmación.
```ruby
client.publish('events', method: :post, body: { type: 'order.placed' })
# → { 'status' => 202, 'body' => nil }
```

---

## FAQ

### ¿Cómo se integra con Rails?
`rails generate bug_bunny:install` genera el inicializador, crea `app/bug_bunny/controllers/` y actualiza `CLAUDE.md`. El pool se define en el inicializador y se asigna a `BugBunny::Resource.connection_pool`.

### ¿Cómo funciona el Health Check?
El consumer ejecuta un check periódico (default 60s) que verifica la conexión AMQP con un `queue.declare(passive: true)`. Si `health_check_file` está configurado, actualiza su mtime. En Kubernetes, usar un `livenessProbe` tipo `exec` que verifique recencia del archivo.

### ¿Cómo funciona el Connection Pool?
Cada slot del pool cachea su `Session` y `Producer` durante su vida útil. Esto evita recrear canales AMQP (costoso) y previene el error de doble `basic_consume`. Thread-safety garantizada por `ConnectionPool`.

### ¿Cómo funciona la cascada de configuración?
3 niveles: Gem defaults → Global config (`BugBunny.configure`) → Per-request (args en `client.request` o `Resource.with`). Se mergean con `merge`.

### ¿Cómo funciona fork safety?
`BugBunny::Railtie` registra hooks en `ActiveSupport::ForkTracker` (Rails 7.1+), `Puma.events.on_worker_boot` y `Spring.after_fork` para llamar `BugBunny.disconnect` y evitar sockets TCP heredados.

---

## Antipatrones

### Consumer en Puma
No ejecutar el `Consumer` dentro de hilos de Puma. Es un bucle bloqueante que saturará el servidor web. Usar un proceso worker dedicado o una tarea Rake separada.

### Reasignación de Pool en Runtime
No asignar `Resource.connection_pool` dentro de controllers o models durante una petición. Es un ajuste global que causa condiciones de carrera y fugas de conexiones.

### Abuso de .with persistente
No guardar el resultado de `Order.with(...)` en una variable para múltiples llamadas. Lanzará error tras la primera ejecución. Para múltiples llamadas, usar siempre la forma de bloque.

### Registrar middleware durante call()
No registrar consumer middlewares durante la ejecución de `call()`. El stack toma un snapshot al inicio; los registros concurrentes no afectan la ejecución actual.

---

## Errores Comunes

### BugBunny::RequestTimeout (408)
**Causa:** No hubo respuesta en `config.rpc_timeout` segundos.
**Resolución:** Verificar que el worker esté activo y que el controlador remoto no lance excepciones silenciosas.

### BugBunny::SecurityError
**Causa:** El mensaje intenta ejecutar un controlador que no hereda de `BugBunny::Controller`.
**Resolución:** Verificar la jerarquía de controladores y que `config.controller_namespace` coincida.

### BugBunny::UnprocessableEntity (422)
**Causa:** Fallo de validación en el servicio remoto.
**Resolución:** `resource.save` devuelve `false`. Acceder a `resource.errors` o `rescue` con `e.error_messages`.

### BugBunny::CommunicationError
**Causa:** Fallo de conexión o reconexión agotada.
**Resolución:** Verificar conectividad a RabbitMQ. Revisar `max_reconnect_attempts` y logs de reconexión.

Ver catálogo completo en [Errores](references/errores.md).

---

## Referencias

- [Routing](references/routing.md) — DSL de rutas, bindings, namespaces, member y collection
- [Controllers](references/controller.md) — Acciones, callbacks, render, rescue_from y log tags
- [Resources](references/resource.md) — CRUD sobre AMQP, .with, callbacks y change tracking
- [Client y Middleware](references/client-middleware.md) — Client, Producer, middleware stack onion
- [Consumer](references/consumer.md) — Subscribe loop, consumer middleware, health check
- [Catálogo de Errores](references/errores.md) — Jerarquía completa de excepciones con resolución
- [Testing](references/testing.md) — RSpec helpers, mocks, patrones de integración
