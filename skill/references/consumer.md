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
  block: true   # false retorna al instante y cierra el canal: no consume nada (#64)
)
```

## Drain (drenar y salir)

Para correr un consumidor **como job**: consume hasta que la cola queda quieta y retorna cuántos mensajes procesó (incluye los rechazados). Con la cola vacía retorna `0` sin esperar.

```ruby
connection = BugBunny.create_connection
begin
  processed_count = BugBunny::Consumer.drain(
    connection: connection,
    queue_name: 'my_app_queue',
    exchange_name: 'my_exchange',
    routing_key: 'users.*'
  )
ensure
  connection.close # drain cierra su canal, no la conexión: la conexión es de quien llama
end
```

- Respeta `channel_prefetch`, igual que `subscribe`.
- Termina tras `drain_idle_timeout` segundos (default `5`) sin entregas y sin nada en proceso; lo chequea cada `drain_poll_interval` (default `0.1`).
- Un mensaje que llega dentro de esa ventana entra en esta vuelta; los posteriores, en la próxima corrida. Una entrega ya recibida al cancelar se procesa antes de volver; si igual no se ack-eara, vuelve a la cola (at-least-once).
- **Con un flujo sostenido no retorna**: si los mensajes llegan más seguido que `drain_idle_timeout`, la ventana nunca vence. Acotalo desde afuera (timeout del job).
- **Una entrega que falla sale de la cola**: si un middleware levanta antes del ack, se rechaza sin requeue y no traba el prefetch.
- **La conexión es de quien llama**: `drain` cierra su canal, no la conexión. Si la creaste para la corrida, cerrala (si no, cada corrida deja una abierta).
- **No** tiene loop de reconexión ni health check: si falla, lo reintenta el framework del job (Bunny sí recupera la conexión por su cuenta con `automatically_recover`).

## Flujo de Procesamiento

1. Escucha en la queue con `manual_ack: true`.
2. Extrae campos **OTel messaging** del mensaje para logs estructurados (sin mutar headers).
3. Valida que el mensaje tenga header `type` (path).
4. Parsea el método HTTP de headers (`x-http-method` o `method`).
5. **Normaliza el path**: remueve slashes iniciales/trailing (`path.gsub(%r{^/|/$}, '')`).
6. Emite log `consumer.message_received` con campos OTel (`messaging_operation: 'process'`).
7. Reconoce la ruta con `BugBunny.routes.recognize(method, normalized_path)`.
8. Resuelve el controlador validando herencia de `BugBunny::Controller`.
9. Ejecuta consumer middlewares → controller callbacks → acción.
10. Responde via `reply_to` si está presente (RPC), inyectando campos OTel (`messaging_operation: 'publish'`).
11. Emite log `consumer.message_processed` con campos OTel y duraciones.
12. Hace `ack` del mensaje. En caso de error, `reject`.

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
| Controller no hereda de BugBunny::Controller | 403 Forbidden + reject + log `event=consumer.security_violation` (guard anti-RCE) |
| Excepción no capturada en controller | 500 + log `event=controller.unhandled_exception` con backtrace |
