# Catálogo de Errores

## Jerarquía

```
StandardError
└── BugBunny::Error
    ├── BugBunny::CommunicationError
    ├── BugBunny::ConfigurationError
    ├── BugBunny::SecurityError
    ├── BugBunny::ClientError (4xx)
    │   ├── BugBunny::BadRequest (400)
    │   ├── BugBunny::NotFound (404)
    │   ├── BugBunny::NotAcceptable (406)
    │   ├── BugBunny::RequestTimeout (408)
    │   ├── BugBunny::Conflict (409)
    │   └── BugBunny::UnprocessableEntity (422)
    └── BugBunny::ServerError (5xx)
        ├── BugBunny::InternalServerError (500+)
        └── BugBunny::RemoteError (500)
```

## Errores de Infraestructura

### BugBunny::CommunicationError
**Causa:** Fallo de conexión TCP/AMQP o reconexión agotada (`max_reconnect_attempts`).
**Cuándo:** Al intentar publicar o consumir sin conexión activa, o tras agotar intentos de reconexión.
**Resolución:** Verificar conectividad a RabbitMQ (host, port, firewall). Revisar logs `event=session.reconnect_failed`. Ajustar `max_reconnect_attempts` y `max_reconnect_interval`.

### BugBunny::ConfigurationError
**Causa:** Campo requerido faltante o valor fuera de rango en `BugBunny.configure`.
**Validaciones:** host (String no vacío), port (1-65535), username/password (no nil), heartbeat (0-3600), rpc_timeout (>0), channel_prefetch (1-10000).
**Resolución:** Revisar el bloque `BugBunny.configure` y corregir valores.

### BugBunny::SecurityError
**Causa:** Un mensaje intenta ejecutar un controlador que no hereda de `BugBunny::Controller`.
**Cuándo:** El consumer resuelve la clase pero falla la validación `is_a?(BugBunny::Controller)`.
**Resolución:** Verificar que el controlador herede de `BugBunny::Controller` y que `config.controller_namespace` sea correcto.

## Errores de Cliente (4xx)

### BugBunny::BadRequest (400)
**Causa:** Request malformado o sintaxis inválida.
**Resolución:** Verificar formato del body y headers.

### BugBunny::NotFound (404)
**Causa:** El recurso solicitado no existe en el servicio remoto.
**Resolución:** Verificar ID del recurso y que el endpoint exista.

### BugBunny::NotAcceptable (406)
**Causa:** Negociación de contenido falló.
**Resolución:** Verificar `content_type` del request.

### BugBunny::RequestTimeout (408)
**Causa:** No hubo respuesta en `config.rpc_timeout` segundos.
**Cuándo:** El `Concurrent::IVar` expira sin recibir reply.
**Resolución:** Verificar que el worker esté activo. Revisar saturación de prefetch. Aumentar `rpc_timeout` si el procesamiento es legítimamente lento.

### BugBunny::Conflict (409)
**Causa:** Conflicto de regla de negocio (ej: recurso ya existe, versión desactualizada).
**Resolución:** Reintentar tras refrescar el estado del recurso.

### BugBunny::UnprocessableEntity (422)
**Causa:** Fallo de validación en el servicio remoto.
**Acceso a errores:**
```ruby
begin
  order.save
rescue BugBunny::UnprocessableEntity => e
  e.error_messages   # Hash, Array o String con detalles
  e.raw_response     # Response original completo
end
```
**Smart extraction:** Busca `errors`, `error`, `detail`, `message` en el body. Formatea como Hash descriptivo si no encuentra convención.
**En Resource:** `save` captura 422 automáticamente, carga `resource.errors` y retorna `false`.

## Errores de Servidor (5xx)

### BugBunny::InternalServerError (500+)
**Causa:** Error no controlado en el servicio remoto.
**Resolución:** Revisar logs del servicio remoto. Verificar backtrace en `event=controller.unhandled_exception`.

### BugBunny::ServerError (base 5xx)
**Causa:** Cualquier error de servidor no mapeado a InternalServerError.
**Resolución:** Similar a InternalServerError.

### BugBunny::RemoteError (500)
**Causa:** Excepción no manejada en el controller remoto. El error se serializa y propaga al cliente RPC.

**Flujo completo:**
1. El controller remoto lanza una excepción (ej: `TypeError`).
2. `BugBunny::Controller#handle_exception` la captura y serializa con `RemoteError.serialize(exception)` → `{ class:, message:, backtrace: }` (máx 25 líneas).
3. El consumer responde con status 500 y el campo `bug_bunny_exception` en el body.
4. El middleware `RaiseError` del cliente detecta `bug_bunny_exception`, reconstituye un `BugBunny::RemoteError` y lo lanza localmente.

**Acceso a detalles:**
```ruby
# Con Client directo
begin
  client.request('users/42', method: :get)
rescue BugBunny::RemoteError => e
  e.original_class     # => "TypeError"
  e.original_message   # => "nil can't be coerced into Integer"
  e.original_backtrace # => Array<String> (backtrace del servicio remoto)
  e.to_s               # => "BugBunny::RemoteError(TypeError): nil can't be coerced into Integer"
end

# Con Resource ORM
begin
  RemoteNode.find('node-123')
rescue BugBunny::RemoteError => e
  Rails.logger.error("Remote #{e.original_class}: #{e.original_message}")
end
```

**Compatibilidad:** Si la respuesta 500 no contiene `bug_bunny_exception` (ej: servicio remoto con versión anterior de BugBunny), se lanza `BugBunny::InternalServerError` en su lugar.

**Herencia:** `RemoteError < ServerError < Error < StandardError`. Se puede capturar con `rescue BugBunny::ServerError` para atrapar tanto `RemoteError` como `InternalServerError`.

## Formato de Mensajes de Error

El middleware `RaiseError` construye el mensaje así:
1. Busca `{ "error": "...", "detail": "..." }` en el body.
2. Si no encuentra, usa el Hash completo como JSON.
3. Si el body está vacío, usa `"Unknown Error"`.

## Connection Pool Missing

**No es una excepción BugBunny**, pero es un error común:
**Causa:** Se intentó usar un Resource sin asignar el pool global.
**Resolución:** Asegurar que `BugBunny::Resource.connection_pool = MY_POOL` se ejecute en el arranque.
