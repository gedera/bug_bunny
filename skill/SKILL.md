---
name: bug_bunny
description: >-
  Routing RESTful sobre AMQP/RabbitMQ para microservicios Ruby/Rails: RPC
  síncrono, fire-and-forget, Publisher Confirms, Resource ORM, controllers y
  routing DSL tipo Rails. Usar cuando se integra/depura comunicación entre
  servicios via RabbitMQ con la gema bug_bunny.
triggers:
  - gema `bug_bunny` / módulo `BugBunny`
  - "símbolos `BugBunny::{Client,Consumer,Resource,Controller}`"
  - "excepciones `BugBunny::{PublishUnroutable,PublishNacked,RemoteError}`"
---

# BugBunny Expert

## Qué es / cuándo usar

Gema Ruby: capa de routing RESTful sobre AMQP/RabbitMQ. Microservicios se comunican via RabbitMQ con ergonomía tipo Rails (verbos, controllers, rutas, RPC síncrono, fire-and-forget, Publisher Confirms). Usar esta dependencia cuando integrás/depurás comunicación entre servicios con `bug_bunny`: publicar/consumir, ORM remoto, manejo de errores de broker.

## Contrato resumido (piso mínimo)

> Resume el contrato de **`bug_bunny` 4.18.0**. Suficiente para el uso típico sin abrir el detalle; el detalle version-locked está en [`../docs/behavior/behavior.md`](../docs/behavior/behavior.md) (6 flujos) y [`../docs/glossary/glossary.md`](../docs/glossary/glossary.md) (símbolos→significado). Antipatrones/API completa: más abajo (embebido interim, ver Cobertura y fronteras).

**Símbolos públicos clave**

| Símbolo | Uso típico |
|---|---|
| `BugBunny::Client` | `client.request(url, method: :get)` (RPC sync) · `client.publish(url, body:)` (fire-and-forget, 202) · `client.publish(url, confirmed: true, mandatory: true)` (publisher confirms) |
| `BugBunny::Resource` | ORM tipo AR: `self.exchange=` / `self.resource_name=` / `connection_pool=`; `find/where/create/save/destroy` |
| `BugBunny::Consumer` | `BugBunny::Consumer.subscribe(connection: BugBunny.create_connection, queue_name:, exchange_name:, routing_key:)` (loop bloqueante) |
| `BugBunny::Controller` | `before/around/after_action`, `rescue_from`, `render status:, json:` |
| `BugBunny.routes.draw` | `resources :x` · `namespace` · `member`/`collection` |
| `BugBunny.configure` | `host/port/username/password` · `rpc_timeout` (default 10) · `nack_raise`/`return_raise` (default `true`) · `on_return` |
| Excepciones | `RemoteError` (500 con backtrace remoto) · `PublishNacked` · `PublishUnroutable` · `RequestTimeout` · `NotFound` · `UnprocessableEntity` · `CommunicationError` (envuelve cualquier `Bunny::Exception` — TCP/conn/canal; `.cause` preserva original) |

**Uso típico**

```ruby
# Servidor
BugBunny.routes.draw { resources :nodes }
BugBunny::Consumer.subscribe(connection: BugBunny.create_connection,
  queue_name: 'inv_q', exchange_name: 'inventory', routing_key: 'nodes')

# Cliente
client = BugBunny::Client.new(pool: pool)
client.request('nodes/42', method: :get)        # => { 'status' => 200, 'body' => {...} }
client.publish('events', body: { type: 'x' })   # => { 'status' => 202 }
```

**Gotchas/breaking críticos**

- URL es **posicional**, no kwarg `path:` — `client.publish(**args)` con `path:` → `ArgumentError`.
- `confirmed: true` ≠ persistente: para sobrevivir restart hace falta `persistent: true` (+ queue `durable`).
- `confirmed:true + mandatory:true` con `return_raise` (default `true`) → `PublishUnroutable` si no rutea.
- `BugBunny::Consumer.subscribe` requiere `connection:`. No correr el Consumer en threads de Puma (loop bloqueante).
- `exchange_options: { durable: true }` debe matchear la declaración del consumer, o `Bunny::PreconditionFailed`.
- **Errores de transporte (4.18+):** TCP fail, conn rota, canal cerrado → siempre `BugBunny::CommunicationError`. No rescatar `Bunny::TCPConnectionFailed`/`ConnectionClosedError` directo — quedó atrás de la frontera. La original sigue accesible vía `.cause`.

## Índice de artefactos (fuente de verdad)

El detalle vive en `docs/<capa>/` (modelo `dev-*`); esta skill **indexa y resume**, no duplica. Links relativos = version-locked (mismo tag del release; `gemspec.files` incluye `docs/**`).

| Capa | Artefacto | Estado |
|---|---|---|
| Glosario de dominio | [docs/glossary/glossary.md](../docs/glossary/glossary.md) | parcial, acreta por PR |
| Comportamiento (flujos) | [docs/behavior/behavior.md](../docs/behavior/behavior.md) | completa — 6 flujos |
| Datos | — | n/a — gema sin DB |
| Operaciones / Interfaz / Topología | — | F2 no implementado — ver Cobertura y fronteras |

> **Glosario:** migrado a [docs/glossary/glossary.md](../docs/glossary/glossary.md)
> (RFC-008 §2 — el compuesto referencia, no copia). Términos AMQP base
> (Exchange, Queue, Routing Key, RPC, Publisher Confirms, Mandatory, etc.) y su
> binding físico están ahí.

## Cobertura y fronteras

**Coexistencia transitoria con destino pendiente (RFC-008 §2 — interim de migración):** mientras la capa de detalle destino (operaciones/interfaz/topología) esté declarada pero **no implementada** (dev-structure F1, F2 del plan), permanecen embebidos bajo el interim normado:

- **En esta skill (abajo):** el contrato detallado (jerarquía de excepciones, API de config, modos de entrega) **y** el diagrama de arquitectura (flujo RPC). El *Contrato resumido* de arriba es el piso mínimo (RFC-008 §2); lo de abajo es el detalle interim hasta que exista `docs/api|interface|topology`.
- **En `README.md`:** el contrato (sin el diagrama de arquitectura).
- **Guías how-to** (`references/*.md`, pre-estándar): destino futuro `docs/howto/`.

Por RFC-008 §2: no se fabrica la capa, no se borra contrato sin destino, no se duplica; migra cuando F2 entregue, mismo PR. Estado transitorio declarado, no excepción permanente. Origen del gap (resuelto, normado): [sequre/ai_knowledge#95](https://github.com/sequre/ai_knowledge/issues/95).

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
| `BugBunny::Producer` | Publica mensajes. Implementa tres modos: `#fire` (async), `#confirmed` (sync con `wait_for_confirms`) y `#rpc` (direct reply-to + `Concurrent::IVar`). |
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

### Eventos de log y duraciones internas

BugBunny mide y emite duraciones automáticamente. **No envolver llamadas a `client.publish` con `Process.clock_gettime` en código de aplicación** — duplica el trabajo. Las duraciones siguen las [OpenTelemetry metric semantic conventions](https://opentelemetry.io/docs/specs/semconv/general/metrics/) (`duration_s` como `Float` en segundos).

| Evento | Nivel | Emitido por | Campos clave |
|---|---|---|---|
| `producer.publish` | INFO | `Producer#publish_message` (pre) | `method`, `path`, `messaging_*` |
| `producer.publish_payload` | INFO | `Producer#publish_message` | `payload` (truncado), `body_size` |
| `producer.publish_detail` | DEBUG | `Producer#publish_message` | `exchange_opts` final |
| `producer.published` | INFO | `Producer#publish_message` (post) | `method`, `path`, `routing_key`, `messaging_message_id`, **`duration_s`** (publish solo) |
| `producer.confirmed` | INFO | `Producer#confirmed` (post-ACK) | `method`, `path`, `routing_key`, **`publish_duration_s`**, **`confirm_duration_s`**, **`duration_s`** (total) |
| `producer.confirms_nacked` | WARN | `Producer#confirmed` (NACK) | `count`, `path` |
| `producer.publish_unroutable` | WARN | `Producer#confirmed` (basic.return) | `path`, `exchange`, `routing_key`, `reply_code`, `reply_text`, `messaging_message_id` |
| `client.return_raise_ignored` | WARN | `Client#publish` | `delivery_mode`, `mandatory` (cuando `return_raise:true` se pasa sin prereqs) |
| `producer.rpc_waiting` | DEBUG | `Producer#rpc` | `messaging_message_id`, `timeout_s` |
| `producer.rpc_response_received` | INFO | `Producer#rpc` (reply recibido) | `method`, `path`, **`duration_s`** (round-trip total), `response_body` |
| `producer.rpc_response_orphaned` | WARN | reply listener | `correlation_id` |
| `consumer.message_received` | INFO | `Consumer#process_message` | `method`, `path`, `messaging_*` |
| `consumer.message_processed` | INFO | `Consumer#process_message` (post) | `response_status`, **`duration_s`**, `controller`, `action`, `messaging_*` |
| `consumer.execution_error` | ERROR | `Consumer#process_message` (rescue) | **`duration_s`**, `error_class`, `error_message` |
| `consumer.route_not_found` | WARN | `Consumer#process_message` | `method`, `path` |
| `consumer.connection_error` | ERROR | `Consumer#subscribe` (retry loop) | `attempt_count`, `retry_in_s`, `error_*` |
| `session.broker_return` | WARN | `Session` (mandatory unrouted) | `reply_code`, `reply_text`, `exchange`, `routing_key` |

**Resumen de qué mide cada `duration_s`:**

- `producer.published.duration_s` — solo el `basic_publish` (TCP enqueue al broker).
- `producer.confirmed.publish_duration_s` — el publish.
- `producer.confirmed.confirm_duration_s` — la espera del ACK del broker (`wait_for_confirms`).
- `producer.confirmed.duration_s` — total (publish + ACK).
- `producer.rpc_response_received.duration_s` — round-trip RPC completo (publish + procesamiento remoto + reply).
- `consumer.message_processed.duration_s` — procesamiento server-side (router + controller + reply).

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

  # Publisher Confirms — fail-loud por default (ambos true).
  # Setear false para volver al comportamiento legacy "log y retorna 202".
  config.nack_raise   = true   # NACK → raise BugBunny::PublishNacked
  config.return_raise = true   # basic.return (mandatory) → raise BugBunny::PublishUnroutable

  # Callback global para basic.return. Corre ANTES del raise PublishUnroutable
  # cuando return_raise es true. Si on_return es nil, BugBunny logea
  # `session.broker_return` con nivel :warn.
  # Firma: ->(return_info, properties, body)
  config.on_return = ->(ri, _props, body) { MyAlerts.unroutable(rk: ri.routing_key, body: body) }

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

## API: Modos de Entrega

| Modo | Espera | Uso | Método |
|---|---|---|---|
| `:rpc` | Reply del consumer remoto | Request-response síncrono | `client.request(...)` |
| `:publish` | Nada | Logs, eventos best-effort | `client.publish(...)` |
| `:confirmed` | ACK del broker (`wait_for_confirms`) | Auditoría, billing, eventos críticos | `client.publish(..., confirmed: true)` |

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

**Confirmed (Publisher Confirms)** — Bloquea hasta el ACK del broker. Garantía de entrega al broker (no al consumer remoto).
```ruby
client.publish('acct.start', exchange: 'acct_x', body: payload,
               confirmed: true, mandatory: true, confirm_timeout: 0.5)
# → { 'status' => 202, 'body' => nil }   # broker ACK confirmado
```

**Receta canónica de publisher productivo (auditoría / billing / accounting):**
```ruby
client.publish('acct.start',
               exchange:         'ingest.radius',
               exchange_type:    :topic,
               exchange_options: { durable: true },    # matchear declaración del consumer
               body:             payload,
               confirmed:        true,                 # broker ACK síncrono
               mandatory:        true,                 # raise PublishUnroutable si no hay binding
               persistent:       true,                 # delivery_mode: 2 — sobrevive restart
               correlation_id:   SecureRandom.uuid,    # tracing explícito
               app_id:           'radius_manager')
```
A partir de 4.17, `persistent`, `correlation_id`, `priority`, `app_id`, `content_type`, `content_encoding` y `expiration` están en `Client::REQUEST_ATTRS` y se aceptan como kwargs. El block API sigue funcionando para overrides puntuales o para atributos no expuestos (`timestamp`, `type`).

**Dos señales del broker, dos excepciones simétricas:**

| Señal | Default | Excepción | Campos |
|---|---|---|---|
| `basic.nack` | raise | `BugBunny::PublishNacked` | `path`, `nacked_count` |
| `basic.return` (mandatory unrouted) | raise | `BugBunny::PublishUnroutable` | `path`, `exchange`, `routing_key`, `reply_code`, `reply_text`, `correlation_id` |

```ruby
# Comportamiento default (4.13+ para nack_raise, 4.15+ para return_raise):
#   broker NACK → PublishNacked
#   mandatory + unroutable → on_return callback (si está) → PublishUnroutable
#   timeout en wait_for_confirms → RequestTimeout
#
# Opt-out (modo "log + 202 silencioso"):
config.nack_raise   = false  # o per-request: nack_raise: false
config.return_raise = false  # o per-request: return_raise: false

# Override per-request gana sobre config global:
client.publish('foo', confirmed: true, mandatory: true, return_raise: false, body: {})
```

**Bridge cross-thread interno (basic.return):** `basic.return` viaja en el reader thread de Bunny (asíncrono). Para hacer `PublishUnroutable` raise-able en el publish thread, BugBunny mantiene un `Session#@pending_returns = Concurrent::Map` correlacionado por `correlation_id`. `Producer#confirmed` auto-asigna `correlation_id` (UUID v4) si falta, registra un `Concurrent::Event` antes del publish, y tras `wait_for_confirms` true espera `RETURN_RACE_WINDOW_S` (50ms) para tolerar GVL scheduling — AMQP garantiza orden wire `return → ack`. El `on_return` user callback se invoca igual antes del raise (orden: signal event → user_cb → raise), así una excepción en el callback no impide el raise.

**Inert cases:** `return_raise: true` sin `mandatory: true` o sin `confirmed: true` emite `client.return_raise_ignored` (WARN) y se ignora — el flag requiere ambos prereqs.

`Bunny::Channel#wait_for_confirms` no soporta timeout nativo en Bunny 2.x. BugBunny lo implementa lanzando la espera en un hilo auxiliar y usando `Concurrent::IVar#value(timeout)` como reloj.

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

**Defaults de la gema desde 4.16:**
- `DEFAULT_EXCHANGE_OPTIONS = { durable: false, auto_delete: false }`
- `DEFAULT_QUEUE_OPTIONS = { exclusive: false, durable: true, auto_delete: false }` — queue compartida duradera, válida en RabbitMQ 3.x y 4.x. Previo a 4.16 era `{ durable: false, auto_delete: true }` (deprecated `transient_nonexcl_queues` en RMQ 4.x). Para legacy: override explícito en `config.queue_options`.

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

### Pasar `path:` como kwarg a `Client#publish` / `#request`
El primer argumento es **posicional** (`url`). No hay kwarg `:path`. Splatear un hash que tenga `path:` falla con `ArgumentError: wrong number of arguments`. Construir args sin path y pasar la URL aparte:
```ruby
args = { exchange: 'x', body: payload }
client.publish('event.name', **args)   # ✅
client.publish(**args.merge(path: 'event.name'))  # ❌
```

### Asumir que `confirmed: true` implica persistencia
`confirmed: true` solo activa Publisher Confirms (broker ACK síncrono). **NO** setea `delivery_mode: 2`. El default de `Request#persistent` es `false` — el mensaje vive en RAM del broker y se pierde si reinicia. Para eventos críticos sobre queue durable hay que pasar `persistent: true` (a partir de 4.17) o setearlo via block. Tabla de decisión:

| Necesitás | Pasar |
|---|---|
| Broker confirma recepción | `confirmed: true` |
| Mensaje sobrevive restart | `persistent: true` (requiere queue `durable: true`) |
| Raise si no rutea | `mandatory: true` (+ `return_raise: true` default) |

### Olvidar `exchange_options: { durable: true }` en publishers a exchange compartido
`DEFAULT_EXCHANGE_OPTIONS = { durable: false, auto_delete: false }`. Si un consumer previamente declaró el exchange como durable (caso normal en producción), un publisher que use el default va a recibir `Bunny::PreconditionFailed - inequivalent arg 'durable'` al re-declarar. Solución: pasar `exchange_options: { durable: true }` en el publisher, o setear global `BugBunny.configure { |c| c.exchange_options = { durable: true } }`.

### Confiar en `instance_double(BugBunny::Client)` para detectar errores de signature
Limitación de RSpec: `instance_double` valida que el método exista pero **no** valida arity estricta cuando el caller hace `**args` splat. Tests con mocks pasan, integration con broker real rompe. Mitigación: para cada publisher nuevo, sumar un smoke spec `:integration` que declare queue exclusiva con binding, publique, haga `queue.pop`, y verifique `correlation_id`, `delivery_mode`, `headers`, `routing_key`.

---

## Errores Comunes

### BugBunny::RequestTimeout (408)
**Causa:** No hubo respuesta en `config.rpc_timeout` segundos.
**Resolución:** Verificar que el worker esté activo y que el controlador remoto no lance excepciones silenciosas.

### BugBunny::SecurityError
**Causa:** El mensaje intenta ejecutar un controlador que no hereda de `BugBunny::Controller`.
**Resolución:** Verificar la jerarquía de controladores y que `config.controller_namespace` coincida.

### BugBunny::RouteNotFoundError (404)
**Causa:** El path del mensaje no coincide con ninguna ruta registrada. El path debe estar normalizado (sin slashes iniciales/trailing).
**Resolución:** Verificar que el cliente envíe el path sin leading/trailing slashes (ej: `users/42`, no `/users/42/`).

### BugBunny::UnprocessableEntity (422)
**Causa:** Fallo de validación en el servicio remoto.
**Resolución:** `resource.save` devuelve `false`. Acceder a `resource.errors` o `rescue` con `e.error_messages`.

### BugBunny::RemoteError (500)
**Causa:** Excepción no manejada en el controller remoto. Se serializa y propaga al cliente RPC con clase, mensaje y backtrace originales.
**Resolución:** `rescue BugBunny::RemoteError => e` y acceder a `e.original_class`, `e.original_message`, `e.original_backtrace`. Revisar logs del consumer (`event=controller.unhandled_exception`).

### BugBunny::CommunicationError
**Causa:** Fallo de transporte AMQP — envuelve cualquier `Bunny::Exception` que escape en la frontera del gem (`Client#publish`/`#request`/`#send`, `Producer#confirmed`, `BugBunny.create_connection`). Cubre TCP fail (`Bunny::TCPConnectionFailed`), conn rota in-flight (`ConnectionClosedError`), canal cerrado (`ChannelAlreadyClosed`), auth fail, etc. La excepción original queda en `.cause`.
**Resolución:** Verificar conectividad a RabbitMQ (host/port/auth/vhost). Inspeccionar `e.cause` para clasificar el fallo concreto. Revisar `max_reconnect_attempts` y logs de reconexión.

**Materia prima (desde 4.19):** todo `BugBunny::Error` de respuesta RPC expone
`e.status` y `e.raw_response` (cuerpo crudo) de forma uniforme — no solo 422. La
gema es agnóstica al payload: el envelope de dominio se parsea en el boundary del
servicio. No loguear `raw_response` sin sanitizar.

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
