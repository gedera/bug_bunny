# Configuración runtime — bug_bunny

> Artefacto **piloto** de RFC-012 (draft, no ratificada en `sequre/ai_knowledge:docs/rfc-draft/RFC-012-configuracion.md`).
>
> **Audiencia:** dev que integra la gema en un servicio Rails (no SRE — la
> gema no lee ENV; el consumidor lo hace). El SRE consulta el `docs/config/`
> de su **servicio**; este doc le sirve solo para entender qué hace
> internamente cada opción que el servicio inyecta a `BugBunny.configure`.
>
> **Régimen:** gema (no aplica §e scheduling; §c meta-templates marginal — ver).

## a. Hecho verificable

- **Total opciones programáticas:** 30 (atributos de `BugBunny::Configuration`).
- **Required validados:** 5 (`host`, `port`, `username`, `password`, `vhost`).
- **Opciones con range validation:** 6 (`port` 1..65535; `heartbeat` 0..3600; `connection_timeout` 1..300; `read_timeout` 1..300; `write_timeout` 1..300; `rpc_timeout` 1..3600; `channel_prefetch` 1..10000).
- **Secrets:** 1 (`password`); 1 opcional (`username` — credencial expuesta, default `guest`).
- **ENV vars leídas por la gema:** **0** (la gema NO lee `ENV[...]` — el consumidor lo hace).
- **Per-call overrides (cascada 3-level):** 12 opciones de conexión aceptan override en `BugBunny.create_connection(**options)`.
- **Per-request overrides (cascada 3-level publish):** 2 (`nack_raise`, `return_raise` se sobrescriben en `Client#publish`).
- **Inyecciones al host Rails (Railtie):** 5 (autoload path, ForkTracker hook, Puma legacy hook, rake tasks, Spring hook).

## b. Inventario

Tablas por familia funcional. La columna `consumidor` cita `file:line` dentro de **esta gema** (no del servicio host).

### b.1 Conexión — `host` / `port` / `username` / `password` / `vhost`

Únicas 5 opciones `required: true` en `VALIDATIONS` (`lib/bug_bunny/configuration.rb:25-37`). Si faltan o son string vacío al cerrar `BugBunny.configure`, levanta `BugBunny::ConfigurationError`.

| nombre | categoría | tipo | req | default | failure-mode | side-effect | scope-override | consumidor | secret? | definición |
|---|---|---|---|---|---|---|---|---|---|---|
| `host` | infra | String | sí | `127.0.0.1` | boot-crash | restart | per-call (`create_connection(host:)`) | `configuration.rb:40,182` | no | host del broker RabbitMQ |
| `port` | infra | Integer (range 1..65535) | sí | `5672` | boot-crash | restart | per-call | `configuration.rb:43,183` | no | puerto del broker |
| `username` | infra | String | sí | `guest` | boot-crash | restart | per-call | `configuration.rb:46,184` | no | usuario AMQP — **default `guest` débil**, el consumidor debe override |
| `password` | infra | String (secret) | sí | `guest` | boot-crash | restart | per-call | `configuration.rb:49,185` | **sí** | password AMQP — default `guest` débil, override mandatorio en prod |
| `vhost` | infra | String | sí | `/` | boot-crash | restart | per-call | `configuration.rb:52,186` | no | virtual host AMQP |

**Helper derivado:** `Configuration#url` (`configuration.rb:224-226`) compone `"amqp://#{username}:#{password}@#{host}:#{port}/#{vhost}"` — ver §d.1.

### b.2 Logger — `logger` / `bunny_logger`

| nombre | categoría | tipo | req | default | failure-mode | side-effect | scope-override | consumidor | secret? | definición |
|---|---|---|---|---|---|---|---|---|---|---|
| `logger` | observability | `Logger` | no | `Logger.new($stdout)` level `INFO` | silent (no method) | restart | mutable-singleton | `configuration.rb:55,188-189` | no | logger de la gema (logs estructurados de session/consumer/producer) |
| `bunny_logger` | observability | `Logger` | no | `Logger.new($stdout)` level `WARN` | silent | per-call (`create_connection(logger:)` lo pasa al driver) | mutable-singleton | `configuration.rb:58,191-192` | no | logger del **driver Bunny** subyacente (separado del logger de la gema para silenciar ruido de Bunny sin perder logs propios) |

**Validación:** NINGUNA. No están en `VALIDATIONS` (decisión documentada en `configuration.rb:18-19`: "tipos arbitrarios no tienen sentido validar genéricamente"). Si el consumidor pasa un objeto que no responde a `info/warn/error`, falla en runtime al primer log.

### b.3 Reconexión / recovery — 4 opciones

| nombre | categoría | tipo | req | default | failure-mode | side-effect | scope-override | consumidor | secret? | definición |
|---|---|---|---|---|---|---|---|---|---|---|
| `automatically_recover` | tuning | Boolean | no | `true` | silent | restart | per-call | `configuration.rb:61,193` | no | si `true`, Bunny reintenta reconexión automática al perder TCP. **Si `false`, el consumidor maneja recovery manual** (caso box_radius_manager) |
| `network_recovery_interval` | tuning | Integer (s) | no | `5` | silent | restart | boot-only | `configuration.rb:64,194` | no | base del backoff exponencial entre reintentos |
| `max_reconnect_attempts` | tuning | Integer or `nil` | no | `nil` (∞) | silent | restart | boot-only | `configuration.rb:67-68,195` | no | techo de reintentos del **Consumer** (no del driver). `nil` = reintentos infinitos |
| `max_reconnect_interval` | tuning | Integer (s) | no | `60` | silent | restart | boot-only | `configuration.rb:71,196` | no | techo del backoff exponencial — el sleep nunca crece más allá |

### b.4 Timeouts — 5 opciones

| nombre | categoría | tipo (range) | req | default | failure-mode | side-effect | scope-override | consumidor | secret? | definición |
|---|---|---|---|---|---|---|---|---|---|---|
| `connection_timeout` | tuning | Integer (s, range 1..300) | no | `10` | boot-crash (out-of-range) | restart | per-call | `configuration.rb:74,197` | no | timeout de TCP connect inicial |
| `read_timeout` | tuning | Integer (s, range 1..300) | no | `30` | boot-crash | restart | per-call | `configuration.rb:77,198` | no | timeout de read socket |
| `write_timeout` | tuning | Integer (s, range 1..300) | no | `30` | boot-crash | restart | per-call | `configuration.rb:80,199` | no | timeout de write socket |
| `heartbeat` | tuning | Integer (s, range 0..3600) | no | `15` | boot-crash | restart | per-call | `configuration.rb:83,200` | no | intervalo de heartbeat AMQP; `0` = desactivado (no recomendado) |
| `continuation_timeout` | tuning | Integer (**ms**) | no | `15_000` (15 s) | silent (sin range valid) | restart | per-call | `configuration.rb:86,201` | no | timeout de operaciones RPC internas del driver. **Unidad asimétrica: ms** (el resto en segundos) |

**Asimetría documentada:** `continuation_timeout` está en **milisegundos** mientras el resto está en segundos. Inherentemente de la API de Bunny — no se va a normalizar (compat).

### b.5 QoS / RPC — 2 opciones

| nombre | categoría | tipo (range) | req | default | failure-mode | side-effect | scope-override | consumidor | secret? | definición |
|---|---|---|---|---|---|---|---|---|---|---|
| `channel_prefetch` | tuning | Integer (range 1..10000) | no | `1` | boot-crash | restart | boot-only | `configuration.rb:89,202` | no | QoS prefetch (cantidad de mensajes que el consumer pre-carga sin ack) |
| `rpc_timeout` | tuning | Integer (s, range 1..3600) | no | `10` | boot-crash | per-request (`Client#request(timeout:)`) | per-request | `configuration.rb:92,203` | no | timeout máximo para esperar respuesta RPC. **Per-request override** documentado |

### b.6 Health check — 2 opciones

| nombre | categoría | tipo | req | default | failure-mode | side-effect | scope-override | consumidor | secret? | definición |
|---|---|---|---|---|---|---|---|---|---|---|
| `health_check_interval` | observability | Integer (s) | no | `60` | silent | restart | boot-only | `configuration.rb:95,204` | no | intervalo del touch al file de health |
| `health_check_file` | observability | String path or `nil` | no | `nil` (deshabilitado) | silent | restart | boot-only | `configuration.rb:97-101,207` | no | path del touchfile que el orquestador (K8s/Docker swarm) puede chequear como liveness probe. **`nil` = feature desactivada** |

**Ramificador (§g):** si `health_check_file` es nil, el timer thread no inicia; si tiene path, se arranca un thread interno que toca el archivo cada `health_check_interval` segundos.

### b.7 Routing / control — 2 opciones

| nombre | categoría | tipo | req | default | failure-mode | side-effect | scope-override | consumidor | secret? | definición |
|---|---|---|---|---|---|---|---|---|---|---|
| `controller_namespace` | infra | String | no | `BugBunny::Controllers` | runtime-error (NameError) si no existe la constante en routing | restart | boot-only | `configuration.rb:104,210` | no | namespace donde se resuelven los controllers AMQP del consumer |
| `log_tags` | observability | `Array<Symbol|Proc|String>` | no | `[:uuid]` | silent | restart | boot-only | `configuration.rb:107,212` | no | tags inyectados en cada log estructurado de consumer/client |

### b.8 Infraestructura global — `exchange_options` / `queue_options`

| nombre | categoría | tipo | req | default | failure-mode | side-effect | scope-override | consumidor | secret? | definición |
|---|---|---|---|---|---|---|---|---|---|---|
| `exchange_options` | business | `Hash` | no | `{}` | silent | restart | per-resource (cascada §d.3) | `configuration.rb:114,215` | no | defaults globales de declaración de Exchanges (durable, auto_delete, etc.); se fusionan con gema defaults y opciones por recurso |
| `queue_options` | business | `Hash` | no | `{}` | silent | restart | per-resource | `configuration.rb:119,216` | no | defaults globales de declaración de Queues; misma cascada |

### b.9 Middleware — `consumer_middlewares`

| nombre | categoría | tipo | req | default | failure-mode | side-effect | scope-override | consumidor | secret? | definición |
|---|---|---|---|---|---|---|---|---|---|---|
| `consumer_middlewares` | business | `ConsumerMiddleware::Stack` | no | `Stack.new` | silent | restart (post-boot mutaciones también — ver nota) | mutable-singleton | `configuration.rb:123,218` | no | stack de middlewares que ejecuta el consumer por cada mensaje |

**Nota:** declarado `attr_reader` (no `attr_accessor`) — semánticamente "no se reemplaza", pero el `Stack` interno **es mutable**: el consumidor puede llamar `BugBunny.configuration.consumer_middlewares.use(MyMiddleware)` post-boot. Asimetría notable: "reader" no es "immutable". Side-effect efectivo es **mutable-singleton**, no boot-only.

### b.10 Callbacks RPC + return — 3 opciones

| nombre | categoría | tipo | req | default | failure-mode | side-effect | scope-override | consumidor | secret? | definición |
|---|---|---|---|---|---|---|---|---|---|---|
| `rpc_reply_headers` | business | `Proc` or `nil` | no | `nil` | silent | per-request | per-request | `configuration.rb:130,251` | no | callback para inyectar headers AMQP en el reply de un consumer RPC (caso: propagar trace context). **Thread: consumer thread** (ver §h) |
| `on_rpc_reply` | business | `Proc` or `nil` | no | `nil` | silent | per-request | per-request | `configuration.rb:135,252` | no | callback ejecutado en el **publisher** tras recibir el reply RPC (caso: hidratar trace context recibido). **Thread: publisher thread** |
| `on_return` | observability | `Proc` or `nil` | no | `nil` (default log warn) | silent | restart | boot-only | `configuration.rb:138-154,253` | no | callback al recibir return de mensaje publicado con `mandatory: true` no enrutable. **Thread: Bunny reader thread — NO debe bloquear** (ver §h) |

### b.11 Publish guarantees — `nack_raise` / `return_raise`

| nombre | categoría | tipo | req | default | failure-mode | side-effect | scope-override | consumidor | secret? | definición |
|---|---|---|---|---|---|---|---|---|---|---|
| `nack_raise` | business | Boolean | no | `true` (strict) | silent | per-request | **per-request** (`Client#publish(nack_raise:)`) | `configuration.rb:163,254` | no | si `true`, NACK del broker en `Producer#confirmed` levanta `BugBunny::PublishNacked`. Si `false`, solo se logea (modo legacy). **Mode-flag binario** — ver §f |
| `return_raise` | business | Boolean | no | `true` (strict) | silent | per-request | **per-request** (`Client#publish(return_raise:)`) | `configuration.rb:165,255` | no | si `true`, return de mensaje con `mandatory: true` no enrutable levanta `BugBunny::PublishUnroutable`. Inerte si `mandatory: false`. Mode-flag binario |

## c. Patrones / meta-templates

Solo 1 patrón marginal: `exchange_options` + `queue_options` comparten el patrón "Hash de defaults globales con cascada de merge 3-level". Pero son **solo 2**, no escala a meta-template. Se documenta como **convención de cascada en §d.3**, no como meta-template propio.

(En esta gema, 30 opciones con shape muy heterogéneo — no hay sufijos repetidos tipo `RABBIT_ACCOUNTING_*` que justifiquen meta-template.)

## d. Derivaciones / cascadas

### d.1 `Configuration#url` ← `host` + `port` + `username` + `password` + `vhost`

- **Fórmula:** `configuration.rb:224-226`:
  ```ruby
  "amqp://#{username}:#{password}@#{host}:#{port}/#{vhost}"
  ```
- **Razón:** helper para integraciones que esperan URL completa (ej. compat con bibliotecas que aceptan `amqp://...`).
- **Nota:** la URL **expone el password en clear-text**. No logear esta URL — usar `host`/`port` separados para logging.

### d.2 `default_connection_options` ← `configuration.*` (cascada 3-level lectura)

- **Fórmula:** `lib/bug_bunny.rb:121-131` arma un hash de 12 keys a partir de la configuración global.
- **Razón:** `create_connection(**options)` permite override puntual; las options pasadas sobrescriben los defaults globales (via `merge`).
- **Cascada 3-level completa:**
  1. **Nivel 1 — Gema defaults:** `Configuration#initialize` (`configuration.rb:181-220`) setea valores seguros.
  2. **Nivel 2 — Consumer global:** `BugBunny.configure { |c| c.host = ... }` sobrescribe el nivel 1.
  3. **Nivel 3 — Per-call:** `BugBunny.create_connection(host: 'other')` sobrescribe el nivel 2 **solo para esa conexión**.
- **12 opciones que aceptan per-call override:** `host`, `port`, `username`, `password`, `vhost`, `logger` (mapea a `bunny_logger`), `automatically_recover`, `connection_timeout`, `read_timeout`, `write_timeout`, `heartbeat`, `continuation_timeout`.
- **18 opciones que NO aceptan per-call override** (solo nivel 1 + 2): `log_tags`, `controller_namespace`, `health_check_*`, callbacks, `nack_raise`/`return_raise` (estas dos sí tienen **per-request** override — ver §d.4 — pero no per-call de conexión), `exchange_options`, `queue_options`, `consumer_middlewares`.

### d.3 `exchange_options` / `queue_options` — cascada de merge

Aplicación efectiva al declarar un recurso AMQP:
1. **Defaults internos de la gema** (lo que Bunny exige + sane defaults BugBunny — `durable: true` para colas persistentes, etc.).
2. **Config global** (`configuration.exchange_options` / `configuration.queue_options`) — override del consumidor.
3. **Per-resource** (opciones pasadas en `Session#exchange(name, **opts)` / `Session#queue(name, **opts)`) — override puntual.

El consumidor puede override selectivamente sin perder defaults razonables.

### d.4 `nack_raise` / `return_raise` — cascada per-request

- **Nivel 1:** gema default `true` (strict).
- **Nivel 2:** `BugBunny.configure { |c| c.nack_raise = false }` cambia el modo global.
- **Nivel 3 (per-request):** `Client#publish(payload, nack_raise: false, return_raise: false)` sobrescribe **solo para ese publish**.

Es la única cascada **per-request** del shape — el resto de overrides son **per-call de conexión** (level 3 distinto).

## e. Scheduling

**No aplica** — bug_bunny es gema cliente AMQP, no aporta scheduler propio. El consumer corre como proceso/thread del servicio host; el host decide cómo orquestarlo (Sidekiq, SolidQueue, bin/rails, etc.).

(El `health_check_interval` timer es **interno** a la gema, no es scheduling de jobs — corre un thread liviano que toca el `health_check_file`. No encaja en §e queues/cron.)

## f. Mode-flags / feature flags

**No hay feature flags con ramp.** Sí hay 4 toggles binarios operacionales — cada uno cambia **modo de comportamiento**, no se rampean a porcentaje:

| flag | estado-actual default | ámbito | condición de cleanup | razón |
|---|---|---|---|---|
| `nack_raise` | `true` (strict) | global + per-request override | sin cleanup — toggle permanente. El modo `false` queda como **legacy** para integradores que migraron desde versión <4.16 | strict vs legacy: si NACK del broker debe levantar excepción o solo logearse |
| `return_raise` | `true` (strict) | global + per-request override | sin cleanup — toggle permanente | strict vs legacy: si return mandatorio no enrutable debe levantar o solo logearse |
| `automatically_recover` | `true` | global + per-call override | sin cleanup | si Bunny reintenta reconexión automática vs si el consumer la maneja manual (box_radius_manager usa `false`) |
| `health_check_file` por presencia | `nil` (deshabilitado) | global | sin cleanup | feature toggle por presencia de path: nil = deshabilitado; path = timer thread activo |

## g. Ramificadores de configuración

Ramificadores **intra-config** (una opción cambia el comportamiento o aplicabilidad de otras dentro de la misma gema):

| var | valores | ámbito | qué cambia |
|---|---|---|---|
| `health_check_file` | `nil` vs `String path` | intra-config | nil → no se inicia el timer thread; path → timer thread arranca con `health_check_interval` (configuración del intervalo solo aplica si el file está seteado) |
| `automatically_recover` | `true` vs `false` | intra-config | `true` → Bunny driver gestiona recovery, `network_recovery_interval` aplica al driver; `false` → consumer gestiona recovery manual, `max_reconnect_attempts` + `max_reconnect_interval` aplican al loop del consumer |
| `nack_raise` global vs per-request | `true`/`false`/override | intra-config | per-request override **gana** sobre global; permite mezclar comportamiento strict/legacy según tipo de publish |

**No hay ramificadores inter-repo / multi-tenant** — la gema es agnóstica del tenant (caller responsibility).

## h. Threading / fiber context

Cuatro callbacks y dos loggers — cada uno tiene contexto de ejecución distinto. **Crítico para safety: bloquear el callback equivocado frena el reader thread de AMQP**.

| opción | tipo | thread de ejecución | puede bloquear? | safety constraints |
|---|---|---|---|---|
| `on_return` | callback | **Bunny reader thread** (interno del driver) | **NO** | sin I/O sincrónico, sin DB queries, sin HTTP calls, sin locks. Solo logging / publish a queue interna. Bloquear acá frena la recepción de **todos** los returns y confirms del broker |
| `rpc_reply_headers` | callback | consumer thread (al armar reply) | sí (es síncrono) | rápido — se invoca antes de cada `basic_publish` del reply RPC |
| `on_rpc_reply` | callback | publisher thread (tras recibir reply) | sí (es síncrono) | rápido — no debería hacer trabajo pesado, retrasa el caller |
| `consumer_middlewares` | middleware chain | consumer thread (por cada mensaje) | sí (es síncrono) | safe — diseñado para trabajo síncrono. Si bloquea, solo frena ese consumer (no otros) |
| `logger` / `bunny_logger` | logger | multi-thread (concurrent access) | n/a | `Logger` Ruby es thread-safe; no setear formatters / writers no thread-safe |

## i. Inyecciones al host

bug_bunny **es Railtie** (`lib/bug_bunny/railtie.rb`). Cuando la gema se carga en un servicio Rails, inyecta automáticamente al ciclo de vida del host. **El servicio consumidor NO ve este código** salvo que lea el código de la gema.

| tipo | nombre | timing | insertion-point | reversible? | condición |
|---|---|---|---|---|---|
| autoload-path | `app/rabbit` | boot (initializer `bug_bunny.add_autoload_paths`) | `app.config.paths.add` con `eager_load: true` | no | solo si `Dir.exist?(app.root + 'app/rabbit')` |
| fork-hook | `ActiveSupport::ForkTracker.after_fork { BugBunny.disconnect }` | after-initialize | global `ForkTracker` | no | solo si `defined?(ActiveSupport::ForkTracker)` (Rails 7.1+) |
| fork-hook (legacy Puma) | `Puma.events.on_worker_boot { BugBunny.disconnect }` | after-initialize | Puma events DSL | no | solo si `defined?(Puma) && Puma.respond_to?(:events)` (Puma <5) |
| rake-tasks | `bug_bunny:sync` | boot (rake_tasks block) | Rake task registry | no | siempre que rake esté cargado |
| fork-hook (Spring) | `Spring.after_fork { BugBunny.disconnect }` | top-level del Railtie (carga del archivo) | Spring DSL | no | solo si `defined?(Spring)` |

**Razón de los 3 fork-hooks redundantes:** garantizar que `BugBunny.disconnect` se llame **antes** de que un proceso hijo Puma/Spring/genérico empiece a trabajar, para que cada worker abra su propia conexión TCP (no comparta el socket del padre — corrupción inmediata).

**Cómo verlo en el servicio host:** el SRE / dev no ve estas inyecciones en su `docs/config/` propio; las consulta acá vía link version-locked.

## Asimetrías / notas

1. **Validación asimétrica:** solo 11 atributos están en `VALIDATIONS` (los 5 required + 6 con range). Logger, Procs, Hash, Stack — sin validación genérica (decisión documentada en `configuration.rb:18-19`).
2. **Defaults débiles de credenciales:** `username: 'guest'`, `password: 'guest'`. Aceptable porque la gema es para uso programático (consumidor obligado a override), pero peligroso si alguien deja la config por defecto en producción. SRE debe verificar override.
3. **`continuation_timeout` en milisegundos** mientras el resto en segundos — herencia de la API de Bunny, no se normaliza.
4. **`consumer_middlewares` declarado `attr_reader` pero objeto mutable** — semántica "read-only" engañosa. Side-effect efectivo `mutable-singleton`.
5. **`Configuration#url` expone password clear-text** — usar solo como helper de conexión, jamás logear el retorno.

---

**Pendiente:** este artefacto es **piloto** del draft RFC-012 v2.1. La skill
canónica (`dev-structure` + `dev-enrich` extendidos para `docs/config/`) **no
existe aún** — este doc se compuso manualmente contra el shape propuesto.
Cualquier cambio futuro a `Configuration` (atributo nuevo, default cambiado,
range nuevo) debe actualizar este archivo hasta que la skill lo haga
automático.

**Link cruzado a consumers:** los servicios que integran bug_bunny pueden
linkear este archivo desde su propio `docs/config/` para indicar qué opción
están inyectando. Ej. `box_radius_manager`:
`RABBIT_HEARTBEAT → bug_bunny.heartbeat` (ver `bug_bunny/docs/config/configuracion.md#b4-timeouts--5-opciones`).
Hoy el link es por **nombre de archivo**; con version-lock (RFC-008 §2)
debería ser version-pinned al tag del release de bug_bunny.
