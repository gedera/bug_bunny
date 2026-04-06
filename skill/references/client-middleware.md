# Client y Middleware

## Client

API de alto nivel para publicar mensajes. Usa un pool de conexiones y una pila de middlewares.

### Métodos Principales

```ruby
# RPC síncrono — bloquea hasta respuesta
response = client.request('users/123', method: :get, timeout: 30)
response = client.request('users', method: :post, body: { name: 'John' })
# → { 'status' => 200, 'body' => {...} }

# Fire-and-Forget — no bloquea
client.publish('events/user_created', method: :post, body: { user_id: 42 })
# → { 'status' => 202, 'body' => nil }

# General con bloque
client.send(url) { |req| req.delivery_mode = :publish }
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

## Producer (bajo nivel)

El `Producer` es usado internamente por el `Client`. Implementa los dos patrones de entrega.

### RPC

- Usa `amq.rabbitmq.reply-to` (direct reply-to pattern).
- Tracking de `correlation_id` en `Concurrent::Map` (thread-safe).
- Reply listener (`basic_consume`) auto-iniciado en el primer RPC.
- Double-checked locking mutex para seguridad del listener.
- Timeout lanza `BugBunny::RequestTimeout`.

### Fire-and-Forget

- Publica en el exchange y retorna `{ 'status' => 202 }` inmediatamente.
- Sin confirmación de procesamiento.

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
req.delivery_mode         # :rpc o :publish
req.exchange              # String destino
req.exchange_type         # 'direct', 'topic', 'fanout'
req.correlation_id        # UUID auto-generado
req.reply_to              # 'amq.rabbitmq.reply-to' (auto para RPC)
req.timestamp             # Time.now.to_i
req.content_type          # 'application/json'
```

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
