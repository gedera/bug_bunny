# BugBunny — Project Intelligence

## ¿Qué es BugBunny?

BugBunny es una gema Ruby que implementa una capa de enrutamiento RESTful sobre AMQP (RabbitMQ). Permite que microservicios se comuniquen via RabbitMQ usando patrones familiares de HTTP: verbos (GET, POST, PUT, DELETE), controladores, rutas declarativas, RPC síncrono y fire-and-forget.

**Problema que resuelve:** Eliminar el acoplamiento directo entre microservicios via HTTP, usando RabbitMQ como bus de mensajes con la misma ergonomía de un framework web.

## Knowledge Base

- **Docs AI:** `docs/ai/` — conocimiento estructurado para agentes
- **Index:** `docs/ai/_index.md` — manifest con versión, audiencias y archivos
- **Docs humanos:** `docs/_index.md` — manifest de toda la documentación (`howto/`, `concepts.md`)

## Skills disponibles

- `.agents/skills/rabbitmq-expert/` — arquitectura AMQP, exchanges, quorum queues, DLX, HA, clustering

---

## Arquitectura

```
Publisher (Client/Resource)
  └─ Producer → Session → Bunny → RabbitMQ Exchange
                                        │
                                   RabbitMQ Queue
                                        │
Consumer (subscribe loop)
  └─ ConsumerMiddleware::Stack
       └─ process_message
            └─ Router → Controller → Action
                              └─ reply (RPC)
```

### Componentes clave

| Clase | Responsabilidad |
|---|---|
| `BugBunny::Session` | Wrapper de canal Bunny. Declara exchanges y queues. |
| `BugBunny::Consumer` | Subscribe loop. Rutea mensajes a controladores via `BugBunny.routes`. |
| `BugBunny::ConsumerMiddleware::Stack` | Pipeline de middlewares antes de `process_message`. |
| `BugBunny::Producer` | Publica mensajes. Implementa RPC con `Concurrent::IVar`. |
| `BugBunny::Client` | API de alto nivel para el publicador. Pool de conexiones. |
| `BugBunny::Controller` | Base class tipo Rails. `around_action`, `before_action`, `render`. |
| `BugBunny::Resource` | ActiveRecord-like sobre AMQP. `find`, `where`, `create`, etc. |
| `BugBunny::Request` | Value object del mensaje saliente (path, method, params, headers). |
| `BugBunny::Observability` | Mixin de logging estructurado. `safe_log`, `exception_metadata`. |
| `BugBunny::Configuration` | Configuración global. Logger, timeouts, middleware hooks. |

### Flujo RPC completo

1. `Resource.find(id)` → `Client#request` → `Producer#rpc`
2. Producer publica en exchange con `reply_to: 'amq.rabbitmq.reply-to'`
3. `Concurrent::IVar` bloquea el thread principal (`future.value(timeout)`)
4. Consumer recibe → middleware stack → controller → `reply(response)`
5. Reply listener thread setea `future.set({ body:, headers: })`
6. Thread principal: `on_rpc_reply&.call(headers)` → `parse_response(body)`

## Hooks de extensión

```ruby
# Middleware antes de process_message (ej: tracing, auth)
BugBunny.consumer_middlewares.use MyMiddleware

# Headers a inyectar en el reply RPC (ej: trace context actualizado)
config.rpc_reply_headers = -> { { 'X-Amzn-Trace-Id' => Tracer.header } }

# Callback en el thread principal al recibir el reply (ej: hidratar tracer)
config.on_rpc_reply = ->(headers) { Tracer.hydrate(headers['X-Amzn-Trace-Id']) }
```

---

## Dominio y Expertise

Al trabajar en esta gema aplicá expertise en:

- **Ruby idiomático**: módulos, mixins, metaprogramación, `class_attribute`, `Concurrent::*`
- **RabbitMQ / AMQP**: exchanges (direct/topic/fanout), queues, bindings, `reply_to`, `correlation_id`, `properties.headers`, publisher confirms, manual ack
- **Bunny**: la gema Ruby que wrappea AMQP. `channel`, `basic_consume`, `basic_publish`, `IVar`
- **Rails patterns**: `ActiveModel`, `ActiveSupport`, `class_attribute`, `concerns`, `constantize`
- **Rack**: `Rack::Utils.parse_nested_query`, `build_nested_query`

---

## Observability — Estándar de Logging

Esta gema implementa su propio patrón de observability via `BugBunny::Observability`.

### Reglas fundamentales

- **Formato**: `component=x event=clase.evento [key=value ...]` — todo en una línea
- **Nunca** llamar al logger directamente. Siempre usar `safe_log`
- **Nunca** `Kernel#warn`, `$stderr`, `puts`
- **Niveles**: `ERROR`=excepción, `WARN`=inesperado+continuó, `INFO`=normal, `DEBUG`=detalle
- `DEBUG` siempre en bloque: `logger.debug { "k=#{v}" }` — `safe_log` lo maneja internamente
- Duraciones: `Process.clock_gettime(Process::CLOCK_MONOTONIC)`, nunca `Time.now`
- Logger failures **nunca** interrumpen el flujo — `safe_log` tiene `rescue StandardError`

### Uso en clases nuevas

```ruby
class BugBunny::MiClase
  include BugBunny::Observability

  def initialize
    @logger = BugBunny.configuration.logger
  end

  def mi_metodo
    start = monotonic_now
    # ...
    safe_log(:info, "mi_clase.mi_evento", campo: valor, duration_s: duration_s(start))
  rescue StandardError => e
    safe_log(:error, "mi_clase.error", **exception_metadata(e))
  end
end
```

### Naming de eventos

Formato estricto: `"clase.evento"` (string, nunca symbol)

| Evento | Nivel | Cuándo |
|---|---|---|
| `consumer.start` | INFO | Consumer inicia subscribe |
| `consumer.bound` | INFO | Queue bindeada al exchange |
| `consumer.message_received` | INFO | Mensaje recibido, antes del routing |
| `consumer.route_matched` | DEBUG | Ruta encontrada |
| `consumer.message_processed` | INFO | Procesamiento exitoso con duración |
| `consumer.execution_error` | ERROR | Excepción en el procesamiento |
| `producer.publish` | INFO | Mensaje publicado |
| `producer.rpc_waiting` | DEBUG | Bloqueando esperando respuesta |
| `producer.rpc_response_received` | DEBUG | Reply recibido (thread principal) |

### Campos estándar

```ruby
safe_log(:error, "clase.error", **exception_metadata(e))
# => error_class: "RuntimeError", error_message: "..."

safe_log(:info, "clase.evento", duration_s: duration_s(start_time))
# => duration_s: 0.001234

# Valores sensibles se filtran automáticamente:
# password, token, secret, api_key, auth → [FILTERED]
```

---

## Standards de Código

### RuboCop

Esta gema usa **rubocop-rails-omakase**. Todo código nuevo o modificado debe cumplir.

```bash
source /opt/homebrew/opt/chruby/share/chruby/chruby.sh && chruby ruby-3.3.8
bundle exec rubocop
bundle exec rubocop -a   # autocorrect
```

**No corregir código existente no tocado.** Solo el código nuevo o modificado en el PR.

### YARD

Todo método público nuevo o modificado lleva documentación YARD:

```ruby
# Descripción breve.
#
# Descripción extendida si es necesario.
#
# @param name [Type] Descripción
# @return [Type] Descripción
# @raise [ErrorClass] Cuándo se lanza
# @example
#   resultado = mi_metodo(arg)
def mi_metodo(name)
```

```bash
bundle exec yard doc
bundle exec yard stats --list-undoc
```

### RSpec

Tests en `spec/`. Sin mocks de dependencias externas reales (RabbitMQ se mockea con doubles de Bunny).

```bash
source /opt/homebrew/opt/chruby/share/chruby/chruby.sh && chruby ruby-3.3.8
bundle exec rspec
bundle exec rspec spec/bug_bunny/consumer_spec.rb   # archivo específico
```

---

## Entorno de Desarrollo

### Ruby

```bash
source /opt/homebrew/opt/chruby/share/chruby/chruby.sh && chruby ruby-3.3.8
```

Nunca usar `bundle exec ruby` con el Ruby del sistema (2.6). Siempre sourcear chruby primero.

### Worktrees

- **Main**: `/Users/gabriel/src/gems/bug_bunny` (rama `main`)
- **Work**: `/Users/gabriel/src/gems/worktrees/current-5n3` (ramas de feature)
- `main` está checkeado en otro worktree — no se puede hacer `git checkout main` desde el worktree de trabajo

### Push a remoto

SSH está roto en este entorno. Para push siempre:

```bash
git remote set-url origin https://github.com/gedera/bug_bunny.git
git push origin main
git remote set-url origin git@github.com:gedera/bug_bunny.git   # restaurar
```

---

## Release Workflow

Usá el comando `/release` para el flujo completo. Manualmente:

1. Determinar tipo: `patch`=bugfix, `minor`=feature nueva, `major`=breaking change
2. Actualizar `lib/bug_bunny/version.rb`
3. Agregar entrada al tope de `CHANGELOG.md`
4. Commit con mensaje convencional
5. Desde `/Users/gabriel/src/gems/bug_bunny`: `git merge --ff-only <branch>`
6. Push via HTTPS + restaurar SSH
7. `git tag vX.Y.Z && git push origin vX.Y.Z`

**Nunca commitear ni pushear sin permiso explícito del usuario.**
