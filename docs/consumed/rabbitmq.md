# Dependencia consumida: RabbitMQ (vía `bunny`) — bug_bunny

> meta: artefacto consumed · RFC-018 (estructural §a/§b/§d) · generado
> `arch-structure` · anclado a `5eea236`, `bug_bunny.gemspec`,
> `lib/bug_bunny.rb`, `lib/bug_bunny/session.rb`, `lib/bug_bunny/producer.rb`,
> `lib/bug_bunny/middleware/raise_error.rb` · fecha 2026-06-30 · cobertura:
> §a/§b/§d completas; §c (retry/idempotencia) y §e (degradación) sembrados `—`
> (→ `arch-enrich`).

## 1. Resumen

La gema consume **un único sistema externo: el broker RabbitMQ**, vía el SDK
`bunny ~> 2.24` (AMQP 0-9-1). Es el corazón del gem: toda publicación, consumo,
RPC y declaración de infraestructura pasa por `Bunny`. El pooling de conexiones
lo da `connection_pool` (infra, ver §4).

## 2. Cuerpo

### a. Identidad

| campo | valor |
|---|---|
| proveedor / sistema | **RabbitMQ broker** |
| sub-tipo | **externo** (sistema de mensajería, no un repo del fleet) |
| transporte | AMQP 0-9-1 (TCP) |
| cliente nuestro | gem `bunny ~> 2.24` (`bug_bunny.gemspec:36`), envuelto por `BugBunny.create_connection` (`bug_bunny.rb:87`) + `Session` |
| auth | SASL user/pass (`username`/`password` de `Configuration`); URL `amqp://user:pass@host:port/vhost` |
| ancla (doc proveedor) | Bunny: https://github.com/ruby-amqp/bunny · AMQP 0-9-1: https://www.rabbitmq.com/amqp-0-9-1-reference.html |

### b. Operaciones consumidas (subset usado)

| operación Bunny | dónde | qué mandamos / esperamos |
|---|---|---|
| `Bunny.new(opts).start` | `bug_bunny.rb:89,93` | abre `Bunny::Session` (conexión TCP + handshake); espera sesión iniciada |
| `after_recovery_completed` | `bug_bunny.rb:90` | callback de recuperación de conexión → log `bug_bunny.connection_recovered` |
| `session.create_channel` | `session.rb:177` (rescata fallo) | abre canal AMQP |
| reconnect / recovery | `session.rb:285` | reconexión; en fallo → `CommunicationError` |
| publish confirmado | `producer.rb:90` (`Producer#confirmed`) | `basic.publish` + publisher confirms; espera ACK/NACK |
| publisher confirms (`nacked_set`) | `producer.rb:235` | lee NACKs del canal → `PublishNacked` |
| `mandatory: true` + `basic.return` | `producer.rb:325` | mensaje no ruteable → `PublishUnroutable` (reply_code 312 NO_ROUTE) |
| RPC (publish + reply-to consume) | `producer.rb:124,214` | request/response; timeout → `RequestTimeout` |
| AMQP publish/consume genérico | `client.rb:168` | cualquier `Bunny::Exception` en la frontera → `CommunicationError` |

> El mapa completo de operaciones que la gema **expone** (no las que consume)
> es la capa operaciones (RFC-003, `docs/api/`, pendiente F2).

### d. Errores del proveedor → excepción nuestra

`bunny` levanta `Bunny::Exception` (y subclases). La gema las **envuelve** en la
frontera de abstracción. La columna "excepción nuestra" **referencia** el
catálogo `docs/errors/errors.md` (RFC-020), no lo redefine.

| error del proveedor (Bunny) | excepción nuestra | dónde se mapea |
|---|---|---|
| `Bunny::Exception` (TCP fail, auth fail, vhost inválido) al conectar | `CommunicationError` | `bug_bunny.rb:95-98` |
| `Bunny::Exception` al crear canal | `CommunicationError` | `session.rb:177` |
| `Bunny::Exception` en reconexión | `CommunicationError` | `session.rb:285` |
| `Bunny::Exception` en publish confirmado | `CommunicationError` | `producer.rb:90` |
| `Bunny::Exception` / `ConnectionClosedError` en publish/consume | `CommunicationError` | `client.rb:168` |
| NACK del broker (publisher confirms) | `PublishNacked` | `producer.rb:235` |
| `basic.return` (mandatory, no ruteable) | `PublishUnroutable` | `producer.rb:325` |
| timeout esperando reply RPC | `RequestTimeout` | `producer.rb:124,214` |

> Regla: los callers no rescatan `Bunny::*` directo — `rescue
> BugBunny::CommunicationError` cubre cualquier fallo de transporte/broker. La
> original queda en `.cause`.

### c / e. Enriquecimiento

`—` (retry/idempotencia-semántica §c · degradación/qué pasa si RabbitMQ cae §e →
`arch-enrich`, RFC-018).

## 3. Inferencias

- El gem declara **dependencia directa** solo de RabbitMQ-vía-bunny. Las demás
  gemas del gemspec (`activemodel`, `activesupport`, `rack`, `json`,
  `concurrent-ruby`, `ostruct`) son librerías de soporte, no sistemas externos
  consumidos → van a topología (RFC-006), no acá.

## 4. Cobertura y fronteras

- §a/§b/§d **completas** al commit ancla; §c/§e sembrados `—`.
- **`connection_pool` (`>= 2.4`):** utilidad de pooling de las conexiones Bunny
  (`Resource.connection_pool`), **no** un sistema externo con su propio
  contrato de error de red → no es entrada consumed; el timeout de pool
  (`ConnectionPool::TimedStack`) nace dentro de `@pool.with` y termina envuelto
  como `CommunicationError` (ver `CHANGELOG` #49). Pertenece a topología.
- **Subset, no la API completa de Bunny:** solo se documentan las operaciones
  que el gem invoca. Parámetros de tuning (heartbeat, prefetch, timeouts) viven
  en `docs/config/`.
