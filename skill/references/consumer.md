# Consumer

## Subscribe

```ruby
consumer = BugBunny::Consumer.subscribe(
  connection: bunny_session,
  queue_name: 'my_app_queue',
  exchange_name: 'my_exchange',
  routing_key: 'users.*',
  exchange_type: 'topic',
  exchange_opts: { durable: true },
  queue_opts: { auto_delete: false },
  block: true   # Si false, retorna inmediatamente
)
```

## Flujo de Procesamiento

1. Escucha en la queue con `manual_ack: true`.
2. Extrae campos **OTel messaging** del mensaje para logs estructurados (sin mutar headers).
3. Valida que el mensaje tenga header `type` (path).
4. Parsea el método HTTP de headers (`x-http-method` o `method`).
5. Emite log `consumer.message_received` con campos OTel (`messaging_operation: 'process'`).
6. Reconoce la ruta con `BugBunny.routes.recognize(method, path)`.
7. Resuelve el controlador validando herencia de `BugBunny::Controller`.
8. Ejecuta consumer middlewares → controller callbacks → acción.
9. Responde via `reply_to` si está presente (RPC), inyectando campos OTel (`messaging_operation: 'publish'`).
10. Emite log `consumer.message_processed` con campos OTel y duraciones.
11. Hace `ack` del mensaje. En caso de error, `reject`.

## Observability: OTel Fields

El consumer construye automáticamente el hash de campos OTel al inicio de `process_message`:

```ruby
otel_fields = BugBunny::OTel.messaging_headers(
  operation: 'process',
  destination: delivery_info.exchange,
  routing_key: delivery_info.routing_key,
  message_id: properties.correlation_id
)
```

Estos campos se mergean en todos los eventos de log del ciclo de vida del mensaje, permitiendo que ExisRay los rastree sin necesidad de propagarlos manualmente en los headers del usuario.

## Lifecycle

```ruby
consumer.shutdown          # Cierra canal, detiene health check
consumer.session           # Accede al Session subyacente
```

## Consumer Middleware

### Registrar

```ruby
BugBunny.configuration.consumer_middlewares.use MyTracing::Middleware
BugBunny.configuration.consumer_middlewares.use MyAuth::Middleware
```

### Crear Middleware

```ruby
class MyMiddleware < BugBunny::ConsumerMiddleware::Base
  def call(delivery_info, properties, body)
    # Pre-procesamiento (ej: hidratar trace context)
    @app.call(delivery_info, properties, body)
    # Post-procesamiento (ej: cleanup)
  end
end
```

### Comportamiento del Stack

- El stack toma un **snapshot** al inicio de `call()`.
- Registros concurrentes durante la ejecución NO afectan la cadena actual.
- Thread-safe para registros con `use()`.
- Orden FIFO: el primero registrado es el primero en ejecutar.

```ruby
stack.use(A)   # A.call → B.call → core
stack.use(B)
stack.empty?   # false
```

## Health Check

- **Intervalo:** Configurable (default 60s).
- **Verificación:** `queue.declare(passive: true)` para confirmar conexión.
- **Touchfile:** Si `config.health_check_file` está configurado, actualiza mtime.
- **Fallo:** Cierra canal, dispara loop de reconexión.

### Kubernetes Integration

```yaml
livenessProbe:
  exec:
    command:
      - test
      - -f
      - /app/tmp/bb_health
  initialDelaySeconds: 30
  periodSeconds: 60
```

## Reconexión

- Exponential backoff desde `network_recovery_interval` hasta `max_reconnect_interval`.
- Intentos limitados por `max_reconnect_attempts` (nil = infinito).
- Logs estructurados en cada intento: `event=session.reconnect_attempt`.
- Si se agotan intentos: `event=consumer.reconnect_exhausted`, lanza `CommunicationError`.

## Manejo de Errores

| Situación | Respuesta |
|-----------|-----------|
| Ruta no encontrada | 404 + log `event=consumer.route_not_found` |
| Controller no encontrado (namespace) | 404 + log `event=consumer.controller_not_found` |
| Controller no hereda de BugBunny::Controller | `SecurityError` |
| Excepción no capturada en controller | 500 + log `event=controller.unhandled_exception` con backtrace |
