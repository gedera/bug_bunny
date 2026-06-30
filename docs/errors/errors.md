# Errores — bug_bunny

> meta: artefacto errores · RFC-020 · generado `arch-structure` (§a/§b/§d) +
> `arch-enrich` (§c) · anclado a `d0533bf`, `lib/bug_bunny/exception.rb`,
> `remote_error.rb`, `middleware/raise_error.rb`, `controller.rb`, `consumer.rb`
> · fecha 2026-06-30 · cobertura: §a/§b/§d completas (estructura); §c política
> completa (enrich, **inferida** de HTTP/AMQP — verificación humana pendiente).

## 1. Resumen

Catálogo del unhappy path que la gema **emite** a sus consumidores: jerarquía de
excepciones bajo `BugBunny::Error`, el mapeo `status RPC → excepción` que aplica
`Middleware::RaiseError` en el lado cliente, y el shape del envelope de error que
emite el lado worker (`Controller`). La gema es **agnóstica al payload**: expone
la materia prima (`status` + `raw_response`) y no interpreta la estructura de
dominio del cuerpo (#52).

## 2. Cuerpo

### a. Inventario de excepciones públicas

Jerarquía (todas bajo `BugBunny::Error < ::StandardError`):

```
::StandardError
└── BugBunny::Error                      base · attr_accessor :status, :raw_response (#52)
    ├── CommunicationError               fallo de red/conexión/protocolo AMQP
    ├── ConfigurationError               configuración inválida de la gema
    ├── PublishNacked                    broker NACK en publish :confirmed
    ├── PublishUnroutable                broker return (mandatory) sin binding
    ├── ClientError                      base 4xx
    │   ├── BadRequest                   400
    │   ├── NotFound                     404
    │   │   └── RoutingError             404 · ruta RPC inexistente en el remoto
    │   ├── NotAcceptable                406
    │   ├── RequestTimeout               408 · y timeout local de RPC
    │   ├── Conflict                     409
    │   └── UnprocessableEntity          422 · parsea body, expone error_messages
    └── ServerError                      base 5xx
        ├── InternalServerError          500 genérico
        └── RemoteError                  500 · propaga excepción serializada del worker
```

| excepción | jerarquía base | qué la levanta (ancla) |
|---|---|---|
| `Error` | `::StandardError` | base — no se levanta directa salvo `resource.rb:122` (pool ausente) |
| `CommunicationError` | `Error` | `bug_bunny.rb:96`, `session.rb:177,285`, `producer.rb:90`, `client.rb:168` — envuelve cualquier `Bunny::Exception` en la frontera del gem; original en `.cause` |
| `ConfigurationError` | `Error` | `configuration.rb:262,269,277` — validación al final de `BugBunny.configure` |
| `PublishNacked` | `Error` | `producer.rb:235` — NACK del broker en modo `:confirmed`. Attrs: `path`, `nacked_count`. Opt-out `nack_raise: false` |
| `PublishUnroutable` | `Error` | `producer.rb:325` — `basic.return` con `mandatory: true`. Attrs: `path`, `exchange`, `routing_key`, `reply_code`, `reply_text`, `correlation_id`. Opt-out `return_raise: false` |
| `ClientError` | `Error` | `raise_error.rb:170` — 4xx no mapeado explícito |
| `BadRequest` | `ClientError` | `raise_error.rb:38` — status 400 |
| `NotFound` | `ClientError` | `raise_error.rb:155` — status 404 genérico |
| `RoutingError` | `NotFound` | `raise_error.rb:152` — status 404 con `body['error_type'] == 'routing_error'` |
| `NotAcceptable` | `ClientError` | `raise_error.rb:40` — status 406 |
| `RequestTimeout` | `ClientError` | `raise_error.rb:41` (status 408) · `producer.rb:124,214` (timeout local de RPC) |
| `Conflict` | `ClientError` | `raise_error.rb:42` — status 409 |
| `UnprocessableEntity` | `ClientError` | `raise_error.rb:44` — status 422. Parsea body, expone `error_messages` (busca clave `errors`); setea `raw_response` en el ctor |
| `ServerError` | `Error` | `raise_error.rb:168` — 5xx no mapeado explícito |
| `InternalServerError` | `ServerError` | `raise_error.rb:67`, `producer.rb:396` (JSON inválido) — status 500 genérico |
| `RemoteError` | `ServerError` | `raise_error.rb:63` — status 5xx con `body['bug_bunny_exception']`. Attrs: `original_class`, `original_message`, `original_backtrace` |

> `ArgumentError`/`NameError` que levantan `client.rb:51`, `controller.rb:101,171`,
> `routing/*` son de la API de configuración/programación (uso incorrecto del
> dev), no del contrato runtime RPC — no se listan como contrato de error público.

### b. Códigos de estado por superficie

Mapeo `status → excepción` que aplica `Middleware::RaiseError#on_complete`
(`raise_error.rb:32-48`) en el **lado cliente** del RPC. Referencia las
operaciones de RFC-003 (`docs/api/`, hoy pendiente — ver §4), no las redefine.

| superficie | status | excepción levantada | cuándo |
|---|---|---|---|
| Cliente RPC (`RaiseError`) | 200..299 | — (none) | éxito, flujo normal |
| Cliente RPC | 400 | `BadRequest` | bad request |
| Cliente RPC | 404 | `NotFound` / `RoutingError` | recurso / ruta RPC inexistente (`error_type: routing_error`) |
| Cliente RPC | 406 | `NotAcceptable` | content negotiation |
| Cliente RPC | 408 | `RequestTimeout` | timeout reportado por el remoto |
| Cliente RPC | 409 | `Conflict` | conflicto de estado/negocio |
| Cliente RPC | 422 | `UnprocessableEntity` | validación semántica del modelo remoto |
| Cliente RPC | 500..599 | `RemoteError` / `InternalServerError` | error del worker (RemoteError si trae `bug_bunny_exception`) |
| Cliente RPC | otro ≥500 | `ServerError` | 5xx no mapeado |
| Cliente RPC | otro ≥400 | `ClientError` | 4xx no mapeado |
| Productor (publish `:confirmed`) | n/a (AMQP) | `PublishNacked` / `PublishUnroutable` | NACK / return del broker — no es status HTTP |
| Transporte (frontera gem) | n/a (AMQP) | `CommunicationError` | fallo de red/broker, envuelve `Bunny::Exception` |
| **Worker (dispatch)** | **403** | — (no excepción; responde 403 + reject) | guard anti-RCE: clase enrutada no subclase de `BugBunny::Controller` (`consumer.rb:222-228`) |

### c. Política por error

Enriquecimiento `arch-enrich` (RFC-020 §c). Política **inferida** de semántica
HTTP (RFC 9110) + AMQP — verificación humana pendiente (ver §3).

| excepción | retriable | backoff | idempotencia | acción sugerida |
|---|---|---|---|---|
| `CommunicationError` | sí (fallo transitorio de red/broker) | sí (`network_recovery_interval`; Bunny auto-recover) | el retry de un **publish** puede duplicar salvo consumidor idempotente; un **read** RPC es seguro | reintentar con backoff; si persiste, circuit-break y alertar |
| `ConfigurationError` | **no** (bug de config) | — | n/a | fail-fast al boot; corregir el bloque `configure` |
| `PublishNacked` | sí, con cautela (NACK puede ser transitorio: disk full, replicación) | sí | el re-publish puede duplicar → requiere dedup aguas abajo | reintentar acotado; si persiste, alertar (problema del broker) |
| `PublishUnroutable` | **no** (no hay binding para la routing key) | — | n/a | corregir routing key / topología de bindings; alertar (mensaje perdido) |
| `BadRequest` (400) | **no** | — | n/a | corregir el request del cliente |
| `NotFound` (404) | **no** | — | n/a | verificar recurso/identificador |
| `RoutingError` (404) | **no** | — | n/a | corregir verbo/path; el servicio remoto no tiene esa ruta registrada |
| `NotAcceptable` (406) | **no** | — | n/a | corregir content negotiation |
| `RequestTimeout` (408) | sí (transitorio) | sí | el retry de un publish/RPC mutante puede duplicar → idempotencia requerida | reintentar con backoff; subir `rpc_timeout` si es crónico |
| `Conflict` (409) | **no** sin resolver el conflicto | — | depende del flujo | resolver el estado en conflicto antes de reintentar |
| `UnprocessableEntity` (422) | **no** (error semántico/validación) | — | n/a | corregir el payload; leer `error_messages` / `raw_response` |
| `ClientError` (4xx genérico) | **no** (default 4xx) | — | n/a | inspeccionar status concreto |
| `ServerError` (5xx genérico) | sí (transitorio) | sí | idempotencia requerida si la op muta estado | reintentar con backoff |
| `InternalServerError` (500) | sí (transitorio) | sí | idem | reintentar con backoff; si persiste, escalar al dueño del worker |
| `RemoteError` (500) | depende de `original_class` | depende | depende | inspeccionar `original_class`/`original_backtrace`; tratar como bug del worker remoto, no reintentar a ciegas |

### d. Shape del payload de error

**Lado worker → wire (lo que emite `Controller#handle_exception`, `controller.rb:224-233`)**
ante una excepción no mapeada por `rescue_from`:

```json
{
  "status": 500,
  "headers": { },
  "body": {
    "error": "Internal Server Error",
    "detail": "<exception.message>",
    "type": "<exception.class.name>",
    "bug_bunny_exception": {
      "class": "<clase original>",
      "message": "<mensaje original>",
      "backtrace": ["<hasta 25 líneas>"]
    }
  }
}
```

- El envelope `bug_bunny_exception` lo arma `RemoteError.serialize` (`remote_error.rb:29`);
  también lo agrega `Consumer` cuando `status == 500 && exception` (`consumer.rb:325`).
  Es lo que el cliente reconstruye como `RemoteError` (`raise_error.rb:61-64`).
- `render status:, json:` (`controller.rb:242`) deja el shape del body de error de
  dominio a criterio del worker — la gema no lo impone.

**Lado cliente — materia prima expuesta (#52).** Toda excepción derivada de una
respuesta RPC trae, vía `RaiseError#raise_typed` (`raise_error.rb:82-86`):

- `e.status` → `Integer` (el código de la respuesta).
- `e.raw_response` → `Hash | String | nil` (el cuerpo crudo, **sin interpretar**).
  `nil` para errores no-RPC (`CommunicationError`, `ConfigurationError`).

**Shapes que `format_error_message` reconoce para el `.message` humano**
(`raise_error.rb:110-141`, best-effort, **NO contrato**):

1. Envelope anidado: `{ "error": { "message": "..." } }` → extrae `error.message`.
2. Shape plano histórico: `{ "error": "texto", "detail": "..." }` → `"texto - detail"`.
3. Fallback: `body.to_json` (nunca `Hash#inspect`).

`UnprocessableEntity` además expone `error_messages` (`exception.rb:219-263`):
parsea el body, devuelve `parsed['errors']` por convención o el cuerpo completo.

> **Seguridad (cruza RFC-017):** `raw_response` puede contener datos sensibles en
> `details`. La gema lo entrega crudo a propósito; **sanitizar antes de cualquier
> sink** (Sentry/logs) filtrando `password|pass|passwd|secret|token|api_key|auth`
> → `[FILTERED]` es responsabilidad del consumidor (`exception.rb:25-30`).

## 3. Inferencias

- **Guard anti-RCE = 403, no excepción.** El control de seguridad que valida la
  herencia de la clase enrutada vive en `consumer.rb:222-228`: si la clase
  resuelta no es subclase de `BugBunny::Controller`, el worker loguea
  `consumer.security_violation`, responde **403 'Forbidden'** (`handle_fatal_error`)
  y rechaza el mensaje sin requeue — **no levanta una excepción dedicada**. La ex
  `BugBunny::SecurityError` (nunca levantada en ninguna ruta de código) fue
  **eliminada como dead code**; el contrato real del unhappy path de RCE es el 403
  (ver §b). `confidence: high` (verificado por grep exhaustivo + lectura del guard).
- **§b superficies AMQP** (`PublishNacked`/`PublishUnroutable`/`CommunicationError`)
  no tienen status HTTP: son señales del protocolo AMQP, no del envelope RPC. Se
  listan como `n/a (AMQP)` para no forzar un código HTTP inventado.
- **§c política (enrich):** la columna retriable/backoff/idempotencia/acción está
  **inferida** de la semántica estándar (HTTP RFC 9110 para 4xx/5xx, comportamiento
  AMQP para NACK/return/transporte), **no** de una política declarada en el código
  del gem. `confidence: medium`. A confirmar con el dueño del código /
  consumidores reales (sobre todo idempotencia de re-publish y el caso
  `RemoteError`, que depende del `original_class` del worker). El gem **no impone**
  retry: la decisión es del consumidor en su boundary.

## 4. Cobertura y fronteras

- **§a/§b/§d (estructura) + §c (enrich, política inferida) completas** al commit
  ancla. §c marcada `confidence: medium` (ver §3).
- **RFC-003 (`docs/api/`) pendiente:** §b referencia "superficie" de operaciones
  pero la capa operaciones no está generada (dev-structure F2, ver `CLAUDE.md`).
  Cuando se genere, §b debe cruzar las operaciones reales.
- **Frontera con `consumed` (RFC-018):** este artefacto = errores que la gema
  **emite**. Los errores de `Bunny::*` que la gema **consume** y envuelve en
  `CommunicationError` son su mapeo error-proveedor→excepción; viven en
  `docs/consumed/rabbitmq.md` §d (que referencia este catálogo, no lo redefine).
- **Errores internos no-públicos** (rescatados adentro, no cruzan la frontera) y
  los `ArgumentError`/`NameError` de mal-uso de la API de config quedan fuera:
  no son contrato runtime.
