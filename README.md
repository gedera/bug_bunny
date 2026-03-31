# 🐰 BugBunny

[![Gem Version](https://badge.fury.io/rb/bug_bunny.svg)](https://badge.fury.io/rb/bug_bunny)

**Active Record over AMQP.**

BugBunny transforma la complejidad de la mensajería asíncrona (RabbitMQ) en una arquitectura familiar RESTful. Permite que tus microservicios se comuniquen como si fueran APIs locales, utilizando controladores, rutas y modelos con una interfaz idéntica a Active Record.

## ✨ Características

*   **RESTful Routing:** Define tus endpoints AMQP con un DSL estilo Rails (`get`, `post`, `resources`).
*   **Active Record Pattern:** Modela tus recursos remotos con validaciones, callbacks y tracking de cambios.
*   **Middleware Stack:** Arquitectura de cebolla (Onion) para interceptar peticiones, manejar errores y transformar payloads.
*   **RPC & Pub/Sub:** Soporta nativamente tanto peticiones síncronas (Request-Response) como publicaciones asíncronas.
*   **Observabilidad de Clase Mundial:** Integración nativa con **ExisRay** (Tracing distribuido y Logs estructurados KV).
*   **Resiliencia Enterprise:** Reconexión automática con Backoff Exponencial y Health Checks automáticos.

---

## 🚀 Instalación

Añade esta línea al `Gemfile` de tu aplicación:

```ruby
gem 'bug_bunny'
```

Y luego ejecuta:
```bash
$ bundle install
```

O instálalo manualmente:
```bash
$ gem install bug_bunny
```

Luego, genera el inicializador (en Rails):
```bash
$ rails generate bug_bunny:install
```

---

## 🛠️ Configuración

Configura la conexión a RabbitMQ y las opciones globales:

```ruby
# config/initializers/bug_bunny.rb
BugBunny.configure do |config|
  config.host = ENV['RABBITMQ_HOST'] || '127.0.0.1'
  config.port = 5672
  config.username = 'guest'
  config.password = 'guest'
  
  # Resiliencia
  config.max_reconnect_attempts = 10      # Falla tras 10 intentos (útil en K8s)
  config.max_reconnect_interval = 60      # Máximo 60s entre reintentos
  config.network_recovery_interval = 5    # Intervalo base para backoff
  
  # Infraestructura por defecto (Nivel 2)
  config.exchange_options = { durable: true }
end
```

---

## 📦 Uso como Modelo (Consumer + Producer)

BugBunny permite definir modelos que representan recursos en otros microservicios.

```ruby
class RemoteNode < BugBunny::Resource
  # Configuración del canal
  self.exchange = 'inventory_exchange'
  self.resource_name = 'nodes' # Equivale al path de la URL

  # Atributos (ActiveRecord style)
  attribute :name, :string
  attribute :status, :string
  attribute :cpu_cores, :integer

  # Validaciones
  validates :name, presence: true
end

# Uso:
node = RemoteNode.find('node-123')
node.status = 'active'
node.save # Realiza un PUT a inventory_exchange con routing_key 'nodes.node-123'

# Búsqueda con filtros (query params)
# Los filtros se serializan como query string en el header 'type' del mensaje.
# El consumer los recibe en params[] igual que en Rails.
RemoteNode.all                               # GET nodes
RemoteNode.where(status: 'active')           # GET nodes?status=active
RemoteNode.where(q: { cpu_cores: 4 })        # GET nodes?q[cpu_cores]=4
```

---

## 🛣️ Enrutamiento y Controladores (Server side)

Define cómo debe responder tu aplicación a los mensajes entrantes:

```ruby
# config/rabbit_routes.rb
BugBunny.routes.draw do
  resources :nodes do
    member do
      put :drain
    end
  end
end

# app/controllers/bug_bunny/nodes_controller.rb
module BugBunny
  module Controllers
    class NodesController < BugBunny::Controller
      def index
        nodes = Node.all # Lógica local de tu app
        render status: :ok, json: nodes
      end

      def drain
        # El ID viene automáticamente en params[:id]
        Node.find(params[:id]).start_drain_process!
        render status: :accepted, json: { message: "Draining started" }
      end
    end
  end
end
```

> **Namespace de Controladores:** Por defecto BugBunny busca los controladores bajo `BugBunny::Controllers`. Podés cambiarlo en la configuración:
> ```ruby
> BugBunny.configure do |config|
>   config.controller_namespace = 'MyApp::RabbitControllers'
> end
> ```

---

## 🔌 Middlewares

Puedes extender el comportamiento del cliente globalmente o por recurso:

```ruby
# Globalmente en el inicializador
BugBunny.configure do |config|
  # ...
end

# Uso con el cliente manual
client = BugBunny::Client.new(pool: BUG_BUNNY_POOL) do |stack|
  stack.use BugBunny::Middleware::RaiseError
  stack.use BugBunny::Middleware::JsonResponse
end

# 1. Método genérico 'send' (Estilo Faraday)
# El comportamiento (RPC o Fire-and-forget) depende de 'delivery_mode'
client.delivery_mode = :rpc # Default
client.send('users/1', method: :get)

# 2. Configuración flexible del modo de entrega
# Por cada petición
client.send('logs', method: :post, body: { msg: 'system_up' }, delivery_mode: :publish)

# O mediante un bloque para configuración avanzada
client.send('users/1') do |req|
  req.method = :get
  req.delivery_mode = :rpc
  req.timeout = 5
end

# 3. Query params (estilo Faraday)
# Usá req.params para enviar filtros. La gema los serializa como query string
# en el header 'type' del mensaje (que el consumer usa para rutear).
# La routing_key del exchange NO se ve afectada.
client.request('users') do |req|
  req.method = :get
  req.params = { q: { active: true }, page: 2 }
end
# Equivalente usando args:
client.request('users', method: :get, params: { q: { active: true }, page: 2 })

# 4. Métodos de conveniencia (Atajos)
client.request('users/1') # Siempre :rpc
client.publish('events', body: { type: 'click' }) # Siempre :publish

# Ahora el cliente devolverá Hashes y lanzará errores si el worker falla
response = client.request('users/1', method: :get)
```

**Middlewares Personalizados**

```ruby
class MyCustomMiddleware < BugBunny::Middleware::Base
  def call(request)
    puts "Enviando mensaje a: #{request.path}"
    app.call(request)
  end
end
```

---

## 🔗 Consumer Middleware Stack

BugBunny expone un middleware stack que se ejecuta **antes** de que la gema procese cada mensaje entrante (antes del primer log `consumer.message_received`). Es el punto ideal para hidratar contexto de tracing distribuido, autenticación, auditoría, etc.

### Implementar un middleware

```ruby
class MyMiddleware < BugBunny::ConsumerMiddleware::Base
  def call(delivery_info, properties, body)
    # lógica pre-procesamiento
    # properties.headers contiene todos los headers AMQP custom
    @app.call(delivery_info, properties, body)
    # lógica post-procesamiento (opcional)
  end
end
```

### Registrar un middleware

```ruby
BugBunny.configure do |config|
  # ...
end

BugBunny.consumer_middlewares.use MyMiddleware
```

### Auto-registro desde una gema externa

Las gemas de integración pueden registrarse automáticamente al ser requeridas, sin que el usuario tenga que tocar el bloque `configure`:

```ruby
# lib/exis_ray/bug_bunny/consumer_tracing.rb
require 'exis_ray/bug_bunny/consumer_tracing_middleware'
BugBunny.consumer_middlewares.use ExisRay::BugBunny::ConsumerTracingMiddleware

# El usuario solo necesita:
# require 'exis_ray/bug_bunny/consumer_tracing'
```

### Datos disponibles en el middleware

| Argumento | Tipo | Contenido |
|---|---|---|
| `delivery_info` | `Bunny::DeliveryInfo` | `routing_key`, `exchange`, `delivery_tag` |
| `properties` | `Bunny::MessageProperties` | `headers` (headers AMQP custom), `correlation_id`, `reply_to`, `content_type` |
| `body` | `String` | Payload crudo del mensaje |

> **Orden de ejecución:** FIFO — el primero en registrarse es el primero en ejecutarse.
> `Middleware A → Middleware B → process_message`

---

## 🔎 Observabilidad y Tracing

BugBunny implementa Distributed Tracing nativo y sigue los estándares de observabilidad de **ExisRay** para logs estructurados.

### 1. Logs Estructurados (Key-Value)
A partir de la v4.3.0, todos los logs internos de la gema utilizan un formato `key=value` optimizado para motores de logs (CloudWatch, Datadog, ELK).

*   **Data First:** Las unidades están en la llave (`_s`, `_ms`, `_count`), permitiendo que los valores sean números puros para agregaciones automáticas.
*   **Reloj Monotónico:** Las duraciones (`duration_s`) se calculan con precisión de microsegundos usando el reloj monotónico del sistema.
*   **Campos de Identidad:** Todos los logs incluyen `component=bug_bunny` y un `event` semántico.

**Ejemplos de Logs:**
```text
# Mensaje procesado con éxito (incluye duración y status numérico)
component=bug_bunny event=consumer.message_processed status=200 duration_s=0.015432 controller=UsersController action=show

# Error de ejecución (campos estandarizados)
component=bug_bunny event=consumer.execution_error error_class=NoMethodError error_message="undefined method..." duration_s=0.008123

# Reintento de conexión con backoff (sufijos de unidad)
component=bug_bunny event=consumer.connection_error error_message="..." attempt_count=3 retry_in_s=20
```

**Ventaja en Cloud:**
Al usar `duration_s` como un float puro, puedes realizar consultas analíticas directamente en tu motor de logs sin parsear strings:
`stats avg(duration_s), max(duration_s) by controller, action`

### 2. Distributed Tracing
El `correlation_id` se mantiene intacto a través de toda la cadena: `Producer -> RabbitMQ -> Consumer -> Controller`.

### 3. Manejo de Errores Declarativo
Captura excepciones y devuélvelas como códigos de estado AMQP/HTTP.

```ruby
class ApplicationController < BugBunny::Controller
  rescue_from ActiveRecord::RecordNotFound do |e|
    render status: :not_found, json: { error: "Resource missing" }
  end

  rescue_from StandardError do |e|
    safe_log(:error, "application.crash", **exception_metadata(e))
    render status: :internal_server_error, json: { error: "Crash" }
  end
end
```

---

## 📄 Licencia

Código abierto bajo [MIT License](https://opensource.org/licenses/MIT).
