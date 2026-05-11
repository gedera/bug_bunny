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

## Producer (bajo nivel)

El `Producer` es usado internamente por el `Client`. Implementa tres patrones de entrega.

### RPC (`Producer#rpc`)

- Usa `amq.rabbitmq.reply-to` (direct reply-to pattern).
- Tracking de `correlation_id` en `Concurrent::Map` (thread-safe).
- Reply listener (`basic_consume`) auto-iniciado en el primer RPC.
- Double-checked locking mutex para seguridad del listener.
- Timeout lanza `BugBunny::RequestTimeout`.

### Fire-and-Forget (`Producer#fire`)

- Publica en el exchange y retorna `{ 'status' => 202 }` inmediatamente.
- Sin confirmación de procesamiento.

### Confirmed (`Producer#confirmed`)

- Publica y bloquea hasta `channel.wait_for_confirms` del broker.
- Bunny 2.x **no soporta timeout** nativo en `wait_for_confirms` — BugBunny envuelve la llamada en un hilo auxiliar y usa `Concurrent::IVar#value(timeout)` como reloj. Si `confirm_timeout` expira → `BugBunny::RequestTimeout`.
- NACK del broker no es fatal: se logea `producer.confirms_nacked` con `count` y `path`, y retorna 202 igual.
- Si `mandatory: true` y el mensaje no es ruteable, el broker dispara `basic.return`. El handler se atacha vía `Bunny::Exchange#on_return` en `Session#exchange` la primera vez que se resuelve cada exchange (cacheado por nombre, una sola vez por canal) y delega a `Configuration#on_return` o al logger por default.
- Errores del canal se envuelven en `BugBunny::CommunicationError`; errores `BugBunny::Error` pre-existentes se propagan sin envolver.

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
   ├──> publish_message     (exchange.publish con mandatory: true)
   │
   ├──> wait_for_confirms!  (espera ACK del broker, con timeout opcional)
   │
   └──> log_nacks_if_any    (si nacked_set no está vacío → log WARN)

Asíncronamente, si el broker no pudo rutear:
   broker ──basic.return──> Exchange#on_return ──> Session handler ──> Configuration#on_return
                                                                   └──> default: log session.broker_return WARN
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

`:confirmed` cuesta un round-trip al broker pero **no** al consumer remoto — más rápido que RPC, con garantía de entrega al broker. NACK del broker es raro (típicamente por confirm policies internas) y no implica pérdida del mensaje.

## Cascada de Configuración (3 niveles)

```ruby
# Level 1: Gem defaults
{ durable: false, auto_delete: false }   # exchanges
{ exclusive: false, durable: false, auto_delete: true }  # queues

# Level 2: Global config
BugBunny.configure { |c| c.exchange_options = { durable: true } }

# Level 3: Per-request
client.request('users', exchange_options: { durable: true })

# Merge final: Level1.merge(Level2).merge(Level3)
```
