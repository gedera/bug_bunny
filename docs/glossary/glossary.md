# Glosario — bug_bunny

> meta: artefacto `glosario` · RFC-009 (binding opcional, r: §2 materialización no-tabular) · generado dev-enrich (siembra) · anclado a `a5cdb10` · cobertura: parcial, acreta por PR

## 1. Resumen

Vocabulario de dominio (DDD ubiquitous language) del bounded context **bug_bunny**: capa de routing RESTful sobre AMQP. Siembra inicial (dev-enrich: glosario SE PUEDE sembrar = migración desde código + conocimiento). **Gema sin capa de datos** (`docs/data/datos.md` = n/a): por RFC-009 §2 el `Binding:` es **opcional** — se cita solo cuando un símbolo público estable *es* el concepto (clase/value object que lo nombra); concepto o patrón sin símbolo propio → `Binding: n/a`. Nunca binding sintético.

## 2. Cuerpo

## Request
Value object con toda la metadata del mensaje saliente: path, verbo, body, params, headers y opciones AMQP (exchange, routing_key, delivery_mode, persistent, mandatory).

**Binding:**
- `lib/bug_bunny/request.rb` — `BugBunny::Request` (la clase *es* el concepto)

## Delivery Mode
Modo de entrega de un mensaje en este contexto: `:rpc` (síncrono, bloquea esperando reply), `:publish` (fire-and-forget, retorna 202), `:confirmed` (async con ACK del broker).

**Binding:** n/a (modo, no símbolo que sea el concepto; se realiza vía `Client#delivery_mode` / `Producer#{rpc,fire,confirmed}`)

## RPC
Request-response síncrono sobre la pseudo-cola `amq.rabbitmq.reply-to` (Direct Reply-to). El hilo emisor bloquea en un `Concurrent::IVar` hasta el reply o `RequestTimeout`.

**Binding:** n/a (patrón; sin clase que sea "RPC")

## Fire-and-Forget
Publicación asíncrona sin espera de respuesta; el caller retorna `{ 'status' => 202 }` de inmediato.

**Binding:** n/a (patrón; sin clase propia)

## Publisher Confirms
Confirmación del broker (`basic.ack`) de recepción del mensaje, expuesta como `confirmed: true`. Dos señales asíncronas se convierten en excepciones raise-eables en el hilo de publish: `basic.nack` → `PublishNacked`; `basic.return` (mandatory unroutable) → `PublishUnroutable`.

**Binding:** n/a (extensión AMQP; se realiza en `Producer#confirmed`)

## Mandatory
Flag de `basic.publish` que pide al broker retornar el mensaje (`basic.return`) si no es ruteable a ninguna cola. Inerte sin `confirmed: true`.

**Binding:** n/a (flag AMQP)

## Route
Patrón compilado verbo+path → Controller#acción; extrae params nombrados por regex.

**Binding:**
- `lib/bug_bunny/routing/route.rb` — `BugBunny::Routing::Route`

## RouteSet
Registro central de rutas + DSL (`resources`, `namespace`, `member`, `collection`) y `recognize`.

**Binding:**
- `lib/bug_bunny/routing/route_set.rb` — `BugBunny::Routing::RouteSet`

## Controller
Base class tipo Rails que recibe el mensaje deserializado (body+headers) y produce una respuesta HTTP. Soporta `before/around/after_action`, `rescue_from`, `render`.

**Binding:**
- `lib/bug_bunny/controller.rb` — `BugBunny::Controller`

## Consumer
Worker bloqueante que escucha una cola, deserializa, rutea via `RouteSet` al controller y responde (RPC reply o ack). Incluye health check periódico.

**Binding:**
- `lib/bug_bunny/consumer.rb` — `BugBunny::Consumer`

## Producer
Publicador de bajo nivel: serialización, resolución de opciones AMQP, correlación RPC, sincronización de Publisher Confirms.

**Binding:**
- `lib/bug_bunny/producer.rb` — `BugBunny::Producer`

## Session
Wrapper de un canal Bunny con init perezoso, cascada de config (defaults gema → global → request) y resiliencia (double-checked locking, auto-reconnect). Correlaciona `basic.return` cross-thread.

**Binding:**
- `lib/bug_bunny/session.rb` — `BugBunny::Session`

## Client
API de alto nivel con arquitectura onion-middleware: construye `Request`, ejecuta el stack y delega en `Producer` via connection pool.

**Binding:**
- `lib/bug_bunny/client.rb` — `BugBunny::Client`

## Resource
ORM tipo ActiveModel: declara microservicios remotos como objetos Ruby con CRUD (`find`, `where`, `create`, `save`, `destroy`) que emiten RPC/async. `.with` da override de contexto thread-local.

**Binding:**
- `lib/bug_bunny/resource.rb` — `BugBunny::Resource`

## Exchange
Entidad AMQP que rutea mensajes a colas según binding. Declarada con `durable`/`auto_delete` por la cascada de config.

**Binding:** n/a (entidad del broker, no de la gema; se realiza en `Session#exchange`)

## Queue
Entidad AMQP que retiene mensajes hasta que un Consumer se suscribe. Default de la gema desde 4.16: compartida y durable.

**Binding:** n/a (entidad del broker; se realiza en `Session#queue`)

## Routing Key
Clave que el exchange usa para matchear mensaje→binding de cola. Por defecto = `path` del request salvo override explícito.

**Binding:** n/a (concepto AMQP; se computa en `Request#final_routing_key`)

## RemoteError
Error 500 que propaga clase, mensaje y backtrace originales de la excepción del worker remoto al caller RPC.

**Binding:**
- `lib/bug_bunny/remote_error.rb` — `BugBunny::RemoteError`

## PublishNacked
Excepción cuando el broker rechaza (`basic.nack`) un mensaje en modo `:confirmed`. Opt-out con `config.nack_raise = false`.

**Binding:**
- `lib/bug_bunny/exception.rb` — `BugBunny::PublishNacked`

## PublishUnroutable
Excepción cuando un mensaje `mandatory: true` en `:confirmed` no es ruteable a ninguna cola (`basic.return`). Opt-out con `config.return_raise = false`.

**Binding:**
- `lib/bug_bunny/exception.rb` — `BugBunny::PublishUnroutable`

## Consumer Middleware
Cadena transversal que corre antes del dispatch al controller (tracing, auth, logging); recibe `delivery_info`, `properties`, `body`; debe hacer yield.

**Binding:**
- `lib/bug_bunny/consumer_middleware.rb` — `BugBunny::ConsumerMiddleware`

## Observability
Mixin de logging estructurado `key=value` que implementa OTel semantic conventions for messaging; `safe_log` nunca lanza; filtra claves sensibles a `[FILTERED]`.

**Binding:**
- `lib/bug_bunny/observability.rb` — `BugBunny::Observability`

## 3. Inferencias

| Término | Inferencia | confidence | a verificar |
|---|---|---|---|
| "bounded context = bug_bunny" | El significado es local a la gema, no global del ecosistema | inferred | humano confirma encuadre DDD |
| Significado de cada término | Sembrado desde código + glosario ad-hoc migrado del `skill/SKILL.md`; el LLM redactó la prosa | inferred | humano aporta/corrige el significado de negocio (dev-enrich: el LLM infiere menos) |
| `Binding:` a clase que "es el concepto" | Criterio RFC-009 §2 aplicado por el LLM (qué símbolo *es* el término) | inferred | humano confirma que el símbolo materializa el término y no es sintético |

## 4. Cobertura y fronteras

- **Parcial y acreta:** glosario sembrado (RFC-009 §2; dev-enrich "se PUEDE sembrar"). Términos nuevos se agregan en el PR que los introduce. Ausencia ≠ inexistencia.
- **Binding opcional (RFC-009 §2, gap gema-sin-datos resuelto, RFC-009 §5 / issue ai_knowledge#91):** sin capa de datos el `Binding:` se omite/`n/a`; se cita símbolo solo cuando *es* el concepto.
- **Frontera (DAMA-DMBOK):** esto es Business Glossary (term-céntrico). El Data Dictionary (`definición` por columna, RFC-002 §2.c) no aplica — sin tablas.
- **Frescura:** si un PR renombra/elimina una clase con `Binding:`, el reviewer verifica que ningún binding quede colgado (RFC-009 §2).
