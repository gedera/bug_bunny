# Configuración — bug_bunny

> meta: artefacto configuración · RFC-012 (inventario base shape v2.2) · generado
> `arch-structure` · anclado a `5eea236`, `lib/bug_bunny/configuration.rb`,
> `lib/bug_bunny.rb`, `lib/bug_bunny/railtie.rb`,
> `lib/generators/bug_bunny/install/templates/initializer.rb` · fecha 2026-06-30
> · cobertura: §a/§b/§c/§d/§e/§i completas; enriquecimiento (§f categoría/
> failure-mode/side-effect, §g/§h/§j) sembrado `—` (→ `arch-enrich`).

## 1. Resumen

Gema configurable vía `BugBunny.configure { |c| ... }` (`bug_bunny.rb:59`) sobre
la clase `Configuration` (`configuration.rb`): atributos con **code-defaults**
seguros, validados por `validate!` al cierre del bloque. La gema **no lee `ENV[`
en `lib/`**; el `ENV.fetch` vive en el **template** que sugiere al consumidor
(`initializer.rb`). Inyecta al host vía `Railtie`.

## 2. Cuerpo

### a. Hecho verificable

- **Total opciones (`Configuration`):** 29 (attr_accessor/reader).
- **Validadas requeridas (`VALIDATIONS`, `configuration.rb:25-37`):** 5 (`host`,
  `port`, `username`, `password`, `vhost` — `required: true`; igual tienen
  default, `validate!` exige no-vacío).
- **Con default:** 29 (todas; defaults en `initialize`/`init_callback_defaults`).
- **Con rango validado:** 6 (`port`, `heartbeat`, `connection_timeout`,
  `read_timeout`, `write_timeout`, `rpc_timeout`, `channel_prefetch`).
- **Secretas (por nombre):** 1 (`password`).
- **ENV leídas por la gema en `lib/`:** 0 (config 100% por code-default + bloque).

### b. Inventario base

Origen `code-default` salvo nota. Consumidor = `configuration.rb` (default en
`initialize`) salvo indicado.

| nombre | tipo | requerida | default | origen | consumidor | secret? |
|---|---|---|---|---|---|---|
| `host` | String | sí (validate!) | `'127.0.0.1'` | code-default | `configuration.rb:182` | no |
| `port` | Integer | sí (validate!, 1..65535) | `5672` | code-default | `:183` | no |
| `username` | String | sí (validate!) | `'guest'` | code-default | `:184` | no |
| `password` | String | sí (validate!) | `'guest'` | code-default | `:185` | **sí** |
| `vhost` | String | sí (validate!) | `'/'` | code-default | `:186` | no |
| `logger` | Logger | no | `Logger.new($stdout)` INFO | code-default | `:188` | no |
| `bunny_logger` | Logger | no | `Logger.new($stdout)` WARN | code-default | `:191` | no |
| `automatically_recover` | Boolean | no | `true` | code-default | `:193` | no |
| `network_recovery_interval` | Integer | no | `5` | code-default | `:194` | no |
| `max_reconnect_attempts` | Integer/nil | no | `nil` (reintenta ∞) | code-default | `:195` | no |
| `max_reconnect_interval` | Integer | no | `60` | code-default | `:196` | no |
| `connection_timeout` | Integer | no (1..300) | `10` | code-default | `:197` | no |
| `read_timeout` | Integer | no (1..300) | `30` | code-default | `:198` | no |
| `write_timeout` | Integer | no (1..300) | `30` | code-default | `:199` | no |
| `heartbeat` | Integer | no (0..3600) | `15` | code-default | `:200` | no |
| `continuation_timeout` | Integer (ms) | no | `15000` | code-default | `:201` | no |
| `channel_prefetch` | Integer | no (1..10000) | `1` | code-default | `:202` | no |
| `rpc_timeout` | Integer | no (1..3600) | `10` | code-default | `:203` | no |
| `health_check_interval` | Integer | no | `60` | code-default | `:204` | no |
| `health_check_file` | String/nil | no | `nil` (desactivado) | code-default | `:207` | no |
| `controller_namespace` | String | no | `'BugBunny::Controllers'` | code-default | `:210` | no |
| `log_tags` | Array | no | `[:uuid]` | code-default | `:212` | no |
| `exchange_options` | Hash | no | `{}` | code-default | `:215` | no |
| `queue_options` | Hash | no | `{}` | code-default | `:216` | no |
| `consumer_middlewares` | Stack (attr_reader) | no | `Stack.new` | code-default | `:218` | no |
| `rpc_reply_headers` | Proc/nil | no | `nil` | code-default | `:251` | no |
| `on_rpc_reply` | Proc/nil | no | `nil` | code-default | `:252` | no |
| `on_return` | Proc/nil | no | `nil` | code-default | `:253` | no |
| `nack_raise` | Boolean | no | `true` | code-default | `:254` | no |
| `return_raise` | Boolean | no | `true` | code-default | `:255` | no |

> **Override por request:** `nack_raise` y `return_raise` se sobreescriben por
> llamada con `nack_raise:` / `return_raise:` en `Client#publish` (scope-override
> → detalle a `arch-enrich`).

### c. Meta-templates

El install template (`initializer.rb`) **sugiere al consumidor** wirear 4 ENV
(la gema no las lee — el consumidor las pasa al bloque `configure`):

| plantilla | template | instancias |
|---|---|---|
| `RABBITMQ_{X}` → `config.{y}` | `ENV.fetch('RABBITMQ_{X}', '{default}')` | `RABBITMQ_HOST`→host (`'localhost'`), `RABBITMQ_USERNAME`→username (`'guest'`), `RABBITMQ_PASSWORD`→password (`'guest'`), `RABBITMQ_VHOST`→vhost (`'/'`) |

> `spec/spec_helper.rb` usa `RABBITMQ_HOST` / `RABBITMQ_USER` / `RABBITMQ_PASS`
> (nombres distintos al template) — convención de test, no contrato.

### d. Derivaciones simples

- `url` ← `"amqp://#{username}:#{password}@#{host}:#{port}/#{vhost}"`
  (`configuration.rb:225`).
- `create_connection(**options)` ← `merge_connection_options(options)` sobre la
  config global; las options explícitas pisan los defaults (`bug_bunny.rb:88`).

### e. Scheduling

**n/a** — la gema no trae `sidekiq.yml`/`queue.yml`/`recurring.yml` ni cron.
`health_check_interval` es polling interno de salud, no un scheduler.

### i. Inyecciones al host (`Railtie`, `railtie.rb`)

| inyección | qué hace | ancla |
|---|---|---|
| `initializer 'bug_bunny.add_autoload_paths'` | registra `app/rabbit` en el autoloader (Zeitwerk, `eager_load: true`) si existe | `:15-18` |
| `config.after_initialize` → `ForkTracker.after_fork` | cierra la conexión heredada en cada fork (Rails 7.1+) | `:24-26` |
| `config.after_initialize` → `Puma.events.on_worker_boot` | mismo cierre, hook legacy Puma <5 | `:30-34` |
| `rake_tasks` | carga `tasks/bug_bunny.rake` (`bug_bunny:sync`) | `:38-40` |
| `Spring.after_fork` | cierra conexión en preloader Spring | `:43-47` |

### f/g/h/j. Enriquecimiento

`—` (categoría · failure-mode · side-effect · scope-override · business-reason ·
ramificadores intra-config · threading · mapeo de inyección a gemas →
`arch-enrich`, RFC-012).

## 3. Inferencias

- **`requerida` de host/port/username/password/vhost:** `VALIDATIONS` las marca
  `required: true`, pero `initialize` les da default → nunca son `nil` salvo que
  el consumidor las setee a `''`/`nil`. Marcadas `sí (validate!)`: el contrato es
  "no-vacías al cierre del bloque", no "sin default". `confidence: high`.
- **`password` secret?=sí** por nombre (regla RFC-012). El default `'guest'` es
  el usuario default de RabbitMQ (placeholder), **no** un secreto real → ver §4.

## 4. Cobertura y fronteras

- §a/§b/§c/§d/§e/§i **completas** al commit ancla; enriquecimiento sembrado `—`.
- **Linter de secretos (advisory):** `password` default `'guest'` y el template
  `RABBITMQ_PASSWORD` default `'guest'` matchean el patrón de secreto, pero el
  valor es el placeholder default de RabbitMQ, **no** un secreto hardcodeado. El
  consumidor debe inyectar la credencial real vía ENV en prod (lo dice el header
  del template). No es hallazgo de fuga.
- **Fuera de alcance:** la semántica de cada timeout/flag (qué falla si se
  setea mal, side-effects de threading de los callbacks `on_return`/
  `on_rpc_reply` que corren en el hilo del consumidor de Bunny) → `arch-enrich`.
