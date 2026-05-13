# Client y Middleware

## Client

API de alto nivel para publicar mensajes. Usa un pool de conexiones y una pila de middlewares.

### Métodos Principales

```ruby
# RPC síncrono — bloquea hasta respuesta del consumer
response = client.request('users/123', method: :get, timeout: 30)
response = client.request('users', method: :post, body: { name: 'John' })
# → { 'status' => 200, 'body' => {...} }

# Fire-and-Forget — no bloquea
client.publish('events/user_created', method: :post, body: { user_id: 42 })
# → { 'status' => 202, 'body' => nil }

# Publisher Confirms — bloquea hasta ACK del broker (no del consumer)
client.publish('acct.start', exchange: 'acct_x', body: payload,
               confirmed: true, mandatory: true, confirm_timeout: 0.5)
# → { 'status' => 202, 'body' => nil }

# General con bloque — máximo control
client.send(url) do |req|
  req.delivery_mode = :confirmed
  req.mandatory = true
  req.confirm_timeout = 1.0
end
```

### Argumentos de Request

| Argumento | Tipo | Default | Propósito |
|-----------|------|---------|-----------|
| `method` | Symbol | `:get` | Verbo HTTP |
| `body` | Hash/String | nil | Payload del mensaje |
| `headers` | Hash | {} | Headers AMQP custom |
| `params` | Hash | {} | Query string params |
| `timeout` | Integer | config | Override de RPC timeout |
| `exchange` | String | config | Exchange destino |
| `exchange_type` | String | 'direct' | Tipo de exchange |
| `routing_key` | String | path | Override de routing key |
| `exchange_options` | Hash | {} | Cascade level 3 |
| `queue_options` | Hash | {} | Cascade level 3 |
| `confirmed` | Boolean | `false` | En `Client#publish`, flipea `delivery_mode` a `:confirmed`. Bloquea hasta `wait_for_confirms`. |
| `mandatory` | Boolean | `false` | Pide al broker retornar el mensaje si no es ruteable. Solo útil con `confirmed: true`. |
| `confirm_timeout` | Float | `nil` | Segundos máximos a esperar el ACK. `nil` = espera indefinida. Excedido → `BugBunny::RequestTimeout`. |
| `nack_raise` | Boolean | `nil` | Override per-request de `config.nack_raise`. `nil` = usa flag global. |
| `return_raise` | Boolean | `nil` | Override per-request de `config.return_raise`. Requiere `confirmed: true` y `mandatory: true`. |
| `persistent` | Boolean | `false` | `delivery_mode: 2` AMQP. Mensaje sobrevive restart del broker. Requiere queue durable. |
| `correlation_id` | String | nil | ID de correlación AMQP. Auto-asignado UUID en RPC y en `confirmed + mandatory + return_raise`. |
| `priority` | Integer | nil | Prioridad 0-255. Requiere queue con `x-max-priority`. |
| `app_id` | String | nil | Identificador del publisher (AMQP `app-id`). |
| `content_type` | String | `'application/json'` | MIME type del payload. |
| `content_encoding` | String | nil | Encoding del payload (`'gzip'`, `'deflate'`, etc.). |
| `expiration` | String | nil | TTL del mensaje en ms (formato AMQP). |

**Gotcha:** el primer argumento de `Client#publish` / `#request` es **posicional** (`url`). No existe el kwarg `:path`. Splatear un hash con `path:` falla con `ArgumentError` o se ignora silencioso.

**Atributos no expuestos como kwarg** (solo via block API): `timestamp` (default `Time.now.to_i`), `type` (default `full_path`), `reply_to` (RPC interno).

## Producer (bajo nivel)

El `Producer` es usado internamente por el `Client`. Implementa tres patrones de entrega.

### RPC (`Producer#rpc`)

- Usa `amq.rabbitmq.reply-to` (direct reply-to pattern).
- Tracking de `correlation_id` en `Concurrent::Map` (thread-safe).
- Reply listener (`basic_consume`) auto-iniciado en el primer RPC.
- Double-checked locking mutex para seguridad del listener.
- Timeout lanza `BugBunny::RequestTimeout`.
- **Emite `producer.rpc_response_received` (INFO) con `duration_s` = round-trip total** (publish + procesamiento remoto + reply). No medir en código de aplicación.

### Fire-and-Forget (`Producer#fire`)

- Publica en el exchange y retorna `{ 'status' => 202 }` inmediatamente.
- Sin confirmación de procesamiento.
- **Emite `producer.published` (INFO) con `duration_s`** = solo el `basic_publish` (TCP enqueue al broker).

### Confirmed (`Producer#confirmed`)

- Publica y bloquea hasta `channel.wait_for_confirms` del broker.
- Bunny 2.x **no soporta timeout** nativo en `wait_for_confirms` — BugBunny envuelve la llamada en un hilo auxiliar y usa `Concurrent::IVar#value(timeout)` como reloj. Si `confirm_timeout` expira → `BugBunny::RequestTimeout`.
- Si `wait_for_confirms` devuelve `false` (broker NACKea), se logea `producer.confirms_nacked` con `count` y `path`. Por default (`config.nack_raise = true`) levanta `BugBunny::PublishNacked` con `path` y `nacked_count`. Para opt-out: `config.nack_raise = false` o pasar `nack_raise: false` per request — en ese caso solo logea y retorna 202.
- Si `mandatory: true` y el mensaje no es ruteable, el broker dispara `basic.return`. El handler se atacha vía `Bunny::Exchange#on_return` en `Session#exchange` la primera vez que se resuelve cada exchange (cacheado por nombre, una sola vez por canal) y delega a `Configuration#on_return` o al logger por default. **Por default (`config.return_raise = true`)** además levanta `BugBunny::PublishUnroutable` en el publish thread con `path`, `exchange`, `routing_key`, `reply_code`, `reply_text`, `correlation_id`. Para opt-out: `config.return_raise = false` o pasar `return_raise: false` per request — solo logea/invoca callback y retorna 202.
- Errores del canal se envuelven en `BugBunny::CommunicationError`; errores `BugBunny::Error` pre-existentes se propagan sin envolver.
- **Emite `producer.confirmed` (INFO) con tres duraciones desglosadas**: `publish_duration_s` (TCP enqueue), `confirm_duration_s` (`wait_for_confirms`), `duration_s` (total). Útil para distinguir latencia de red vs latencia de confirm policy del broker.

## Middleware Stack (Client-side, Onion Architecture)

```
Request  ─→ RaiseError ─→ JsonResponse ─→ Custom ─→ Producer
Response ←─ RaiseError ←─ JsonResponse ←─ Custom ←─
```

### Registrar Middlewares

```ruby
class Order < BugBunny::Resource
  client_middleware do |stack|
    stack.use BugBunny::Middleware::RaiseError
    stack.use BugBunny::Middleware::JsonResponse
    stack.use MyCustomMiddleware
  end
end
```

### Crear un Middleware Custom

```ruby
class MyMiddleware < BugBunny::Middleware::Base
  def on_request(env)
    # Modificar request antes de enviar
    env.headers['X-Custom'] = 'value'
  end

  def on_complete(response)
    # Modificar response después de recibir
    response['body'] = transform(response['body'])
  end
end
```

El método `call` del `Base` invoca `on_request`, delega a `@app.call`, y luego `on_complete`.

### Middlewares Incluidos

**RaiseError** — Mapea status HTTP a excepciones:

| Status | Excepción |
|--------|-----------|
| 200-299 | (ninguna) |
| 400 | `BadRequest` |
| 404 | `NotFound` |
| 406 | `NotAcceptable` |
| 408 | `RequestTimeout` |
| 409 | `Conflict` |
| 422 | `UnprocessableEntity` (con smart extraction de errors) |
| 500+ | `InternalServerError` / `ServerError` |
| 4xx otros | `ClientError` |

**JsonResponse** — Auto-parsea `response['body']` de String a Hash/Array. Aplica `HashWithIndifferentAccess` si disponible.

## OpenTelemetry: Publisher Injection

El `Producer` (vía `Request#amqp_options`) inyecta automáticamente los campos de OTel semantic conventions en los headers AMQP del mensaje saliente.

```ruby
# Headers inyectados automáticamente
{
  'messaging_system' => 'rabbitmq',
  'messaging_operation' => 'publish',
  'messaging_destination_name' => 'exchange_name',
  'messaging_routing_key' => 'rk',
  'messaging_message_id' => 'uuid'
}
```

El orden de merge es: **OTel base** → **headers del usuario** → **x-http-method**. Esto permite al desarrollador sobrescribir valores de OTel si es necesario, pero garantiza que el ruteo interno (`x-http-method`) se mantenga íntegro.

## Request Object

Value object con toda la metadata AMQP:

```ruby
req.path                  # 'users/123'
req.method                # :get
req.body                  # Hash, Array, String o nil
req.headers               # Hash custom
req.params                # Hash query string
req.full_path             # path + query string
req.delivery_mode         # :rpc, :publish o :confirmed
req.exchange              # String destino
req.exchange_type         # 'direct', 'topic', 'fanout'
req.correlation_id        # UUID auto-generado
req.reply_to              # 'amq.rabbitmq.reply-to' (auto para RPC)
req.timestamp             # Time.now.to_i
req.content_type          # 'application/json'
req.mandatory             # Boolean — solo modo :confirmed
req.confirm_timeout       # Float|nil — solo modo :confirmed
req.nack_raise            # Boolean|nil — override per-request de config.nack_raise (solo modo :confirmed)
```

Cuando `mandatory == true`, `Request#amqp_options` inyecta `mandatory: true` en el hash que va a `basic_publish`.

## Publisher Confirms y `basic.return`

### Flujo

```
client.publish('x', confirmed: true, mandatory: true)
   │
   ▼
Producer#confirmed
   │
   ├──> setup_return_listener  (si return_raise? → Session#register_return_listener(cid))
   │                            │
   │                            └─ @session.@pending_returns[cid] = { event:, info: nil }
   │
   ├──> publish_message         (exchange.publish con mandatory: true, correlation_id auto-asignado)
   │
   ├──> wait_for_confirms!      (espera ACK del broker, con timeout opcional)
   │
   ├──> handle_confirm_result
   │        ├─ acked == true  → continúa
   │        └─ acked == false → log WARN producer.confirms_nacked
   │                              └─ raise BugBunny::PublishNacked  (si config.nack_raise || req.nack_raise)
   │
   ├──> handle_return_result    (si listener registrado)
   │        ├─ slot.event.wait(RETURN_RACE_WINDOW_S = 0.05)
   │        ├─ slot.info == nil → return (ack normal sin return)
   │        └─ slot.info != nil → log WARN producer.publish_unroutable
   │                                └─ raise BugBunny::PublishUnroutable
   │
   └──> ensure: teardown_return_listener (Session#unregister_return_listener(cid))

Asíncronamente en el reader thread, si el broker no pudo rutear:
   broker ──basic.return──> Exchange#on_return ──> Session#handle_broker_return
                                                       │
                                                       ├─ signal_return_listener   (busca cid en @pending_returns,
                                                       │                            setea slot.info + slot.event)
                                                       │
                                                       └─ dispatch_return_callback (invoca Configuration#on_return
                                                                                    o logea session.broker_return)
```

### `Configuration#on_return`

El handler se registra **una sola vez por exchange** en `Session#exchange` (cuando `publisher_confirms: true`) usando `Bunny::Exchange#on_return`. Bunny dispatcha `basic.return` por exchange, no por canal, así que el handler vive en cada `Bunny::Exchange` resuelto vía cascada. `Session` cachea los exchanges ya configurados por nombre en `@configured_returns` para no re-registrar en cada publish; el set se limpia al recrear el canal.

```ruby
BugBunny.configure do |c|
  c.on_return = ->(return_info, properties, body) {
    # return_info: Bunny::ReturnInfo (reply_code, reply_text, exchange, routing_key)
    # properties:  Bunny::MessageProperties
    # body:        String (payload crudo)
    MyAlerts.unroutable(rk: return_info.routing_key, body: body)
  }
end
```

Si `on_return` es `nil` (default), BugBunny logea:

```
component=bug_bunny event=session.broker_return reply_code=312
   reply_text="NO_ROUTE" exchange=evt_x routing_key=acct.start body_size=64
```

Excepciones del callback se capturan y se logean como `session.on_return_failed` para no romper el hilo I/O de Bunny.

### Cuándo usar `:confirmed`

| Escenario | Modo recomendado |
|---|---|
| Logs, eventos best-effort | `:publish` |
| Auditoría, billing, eventos críticos | `:confirmed` (con `mandatory: true` si es ruteable) |
| Request-response síncrono | `:rpc` |

`:confirmed` cuesta un round-trip al broker pero **no** al consumer remoto — más rápido que RPC, con garantía de entrega al broker. Dos modos de falla broker-side, ambos raise-eables por default:

- **NACK** (raro: confirm policies internas, disk full, replicación insuficiente) → `BugBunny::PublishNacked` (`path`, `nacked_count`). Opt-out: `config.nack_raise = false`.
- **basic.return + mandatory** (queue inexistente, sin bindings, routing key sin match) → `BugBunny::PublishUnroutable` (`path`, `exchange`, `routing_key`, `reply_code`, `reply_text`, `correlation_id`). Opt-out: `config.return_raise = false`.

El `on_return` user callback se invoca igual antes del raise (orden: signal interno → user_cb → raise en caller), así que alerting/metrics siguen funcionando.

### Bridge cross-thread (`basic.return` → publish thread)

`basic.return` llega en el reader thread de Bunny mientras el publish thread está dentro de `wait_for_confirms`. Para que `PublishUnroutable` sea raise-eable sincrónicamente desde la perspectiva del caller, `Session` mantiene un registry indexado por `correlation_id`:

```ruby
# Session (api privada)
@pending_returns = Concurrent::Map.new
# slot = { event: Concurrent::Event.new, info: nil }
```

`Producer#confirmed`:
1. Si `return_raise?` resuelto es true, auto-asigna `request.correlation_id` si falta (UUID v4 vía `SecureRandom`).
2. Registra slot vía `Session#register_return_listener(cid)`.
3. Publica con `correlation_id` propagado a las message properties (el broker lo echo back en `basic.return.properties`).
4. Tras `wait_for_confirms` true, `event.wait(RETURN_RACE_WINDOW_S = 0.05)` para tolerar GVL scheduling. AMQP wire garantiza `return → ack`, así que normalmente el event ya está seteado.
5. Si `slot[:info]` no es nil, logea `producer.publish_unroutable` y raise.
6. `ensure` block siempre llama `Session#unregister_return_listener(cid)` para cleanup.

`Session#handle_broker_return` (reader thread):
1. `signal_return_listener` busca cid por `properties.correlation_id`, setea `slot[:info]` y `slot[:event]`. **Esto corre ANTES del user_cb** — una excepción en el callback no impide el raise.
2. `dispatch_return_callback` invoca `Configuration#on_return` o logea `session.broker_return`.

Si `return_raise: true` se pasa sin `confirmed: true` o sin `mandatory: true`, el flag es inerte y se emite `client.return_raise_ignored` WARN. El bridge no aplica en `:publish` puro porque no hay synchronization point (`wait_for_confirms`) sobre el cual raise-ear en el caller.

## Cascada de Configuración (3 niveles)

```ruby
# Level 1: Gem defaults (BugBunny::Session)
{ durable: false, auto_delete: false }                       # DEFAULT_EXCHANGE_OPTIONS
{ exclusive: false, durable: true, auto_delete: false }      # DEFAULT_QUEUE_OPTIONS (cambio en 4.16)

# Level 2: Global config
BugBunny.configure { |c| c.exchange_options = { durable: true } }

# Level 3: Per-request
client.request('users', exchange_options: { durable: true })

# Merge final: Level1.merge(Level2).merge(Level3)
```

**Nota 4.16+:** `DEFAULT_QUEUE_OPTIONS` previamente era `{ exclusive: false, durable: false, auto_delete: true }` (combo `transient_nonexcl_queues` deprecada en RabbitMQ 4.x). El nuevo default es queue compartida duradera. Para restaurar el comportamiento previo: `c.queue_options = { exclusive: false, durable: false, auto_delete: true }`.
