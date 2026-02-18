# 🐰 BugBunny

**BugBunny** es un framework RPC para Ruby on Rails sobre **RabbitMQ**.

Su filosofía es **"Active Record over AMQP"**. Transforma la complejidad de la mensajería asíncrona en una arquitectura **RESTful simulada**. Los mensajes viajan con Verbos HTTP (`GET`, `POST`, `PUT`, `DELETE`) inyectados en los headers AMQP, permitiendo que un **Router Inteligente** despache las peticiones a controladores Rails estándar.

---

## 📦 Instalación

Agrega la gema a tu `Gemfile`:

```ruby
gem 'bug_bunny'
```

Ejecuta el bundle:

```bash
bundle install
```

Genera los archivos de configuración iniciales:

```bash
rails g bug_bunny:install
```

Esto creará:
1.  `config/initializers/bug_bunny.rb`
2.  `app/rabbit/controllers/`

---

## ⚙️ Configuración

### 1. Inicializador y Logging

BugBunny separa los logs de la aplicación (Requests) de los logs del driver (Heartbeats/Frames) para mantener la consola limpia.

```ruby
# config/initializers/bug_bunny.rb

BugBunny.configure do |config|
  # --- Credenciales ---
  config.host     = ENV.fetch('RABBITMQ_HOST', 'localhost')
  config.username = ENV.fetch('RABBITMQ_USER', 'guest')
  config.password = ENV.fetch('RABBITMQ_PASS', 'guest')
  config.vhost    = ENV.fetch('RABBITMQ_VHOST', '/')

  # --- Timeouts ---
  config.rpc_timeout = 10               # Timeout para esperar respuesta (Síncrono)
  config.network_recovery_interval = 5  # Segundos para reintentar conexión

  # --- Logging (Niveles recomendados) ---
  # Logger de BugBunny: Muestra tus requests (INFO)
  rails_logger = Rails.logger

  if defined?(ActiveSupport::TaggedLogging) && !rails_logger.respond_to?(:tagged)
    config.logger = ActiveSupport::TaggedLogging.new(rails_logger)
  else
    config.logger = rails_logger
  end

  # Logger de Bunny (Driver): Silencia el ruido de bajo nivel (WARN)
  if defined?(ActiveSupport::TaggedLogging) && !rails_logger.respond_to?(:tagged)
    config.bunny_logger = ActiveSupport::TaggedLogging.new(rails_logger)
  else
    config.bunny_logger = rails_logger
  end
  config.bunny_logger.level = Logger::WARN

  # Controller Namaspeace
  config.controller_namespace = 'MyApp::AsyncHandlers' # Default: 'Rabbit::Controllers'
end
```

### 2. Connection Pool (Crítico) 🧵

Para entornos concurrentes como **Puma** o **Sidekiq**, es **obligatorio** definir un Pool de conexiones global. BugBunny no gestiona hilos automáticamente sin esta configuración.

```ruby
# config/initializers/bug_bunny.rb

# Define el pool global (ajusta el tamaño según tus hilos de Puma/Sidekiq)
BUG_BUNNY_POOL = ConnectionPool.new(size: ENV.fetch('RAILS_MAX_THREADS', 5).to_i, timeout: 5) do
  BugBunny.create_connection
end

# Inyecta el pool a los recursos para que lo usen automáticamente
BugBunny::Resource.connection_pool = BUG_BUNNY_POOL
```

---

## 🚀 Modo Resource (ORM / Cliente)

Define modelos que actúan como proxies de recursos remotos. BugBunny se encarga de serializar, "wrappear" parámetros y enviar el verbo correcto.

### Definición del Modelo

```ruby
# app/models/manager/service.rb
class Manager::Service < BugBunny::Resource
  # 1. Configuración de Transporte
  self.exchange = 'box_cluster_manager'
  self.exchange_type = 'direct'

  # 2. Configuración Lógica (Routing)
  # Define la URL base y la routing key por defecto.
  self.resource_name = 'services'

  # 3. Wrapping de Parámetros (Opcional)
  # Por defecto usa el nombre del modelo sin módulo (Manager::Service -> 'service').
  # Puedes forzarlo con:
  # self.param_key = 'docker_service'
end
```

### CRUD RESTful

Las operaciones de Ruby se traducen a verbos HTTP sobre AMQP.

```ruby
# --- LEER (GET) ---
# Envia: GET services
# Routing Key: "services"
services = Manager::Service.all

# Envia: GET services/123
service = Manager::Service.find('123')

# --- CREAR (POST) ---
# Envia: POST services
# Body: { "service": { "name": "nginx", "replicas": 3 } }
# Nota: Envuelve los params automáticamente en la clave 'service'.
svc = Manager::Service.create(name: 'nginx', replicas: 3)

# --- ACTUALIZAR (PUT) ---
# Envia: PUT services/123
# Body: { "service": { "replicas": 5 } }
svc.update(replicas: 5)

# --- ELIMINAR (DELETE) ---
# Envia: DELETE services/123
svc.destroy
```

### Contexto Dinámico (`.with`)

Puedes cambiar la configuración (Routing Key, Exchange) para una operación específica sin afectar al modelo global. El contexto se mantiene durante el ciclo de vida del objeto.

```ruby
# La instancia nace sabiendo que pertenece a la routing_key 'urgent'
svc = Manager::Service.with(routing_key: 'urgent').new(name: 'redis')

# ... lógica de negocio ...

# Al guardar, BugBunny recuerda el contexto y envía a 'urgent'
svc.save
# Log: [BugBunny] [POST] '/services' | Routing Key: 'urgent'
```

### Soporte de Parámetros Anidados (Nested Queries)
En la versión 3.0.3 arreglaste la serialización usando `Rack::Utils`. Esto es una "feature" poderosa que permite filtrar por hashes complejos, algo muy común en APIs modernas.

**Sugerencia:** Agregar un ejemplo en la sección **CRUD RESTful > LEER (GET)**:

```ruby
# --- LEER CON FILTROS AVANZADOS ---
# Soporta hashes anidados (gracias a Rack::Utils)
# Envia: GET services?q[status]=active&q[tags][]=web
Manager::Service.where(q: { status: 'active', tags: ['web'] })
```

### 🔌 Manipulación de Headers (Middleware)

BugBunny permite interceptar y modificar las peticiones antes de que se envíen a RabbitMQ utilizando `client_middleware`. Esto es ideal para inyectar trazas, autenticación o metadatos de contexto.

Existen 3 formas principales de usarlo:

#### 1. Definición Inline (Rápida)
Ideal para inyectar headers estáticos específicos de un recurso.
```ruby
class Payment < BugBunny::Resource
  client_middleware do |stack|
    stack.use(Class.new(BugBunny::Middleware::Base) do
      def on_request(env)
        env.headers['X-Service-Version'] = 'v2'
        env.headers['Content-Type'] = 'application/json'
      end
    end)
  end
end
```

#### 2. Clase Reutilizable (Recomendada)
Si tienes lógica compartida (ej: Autenticación), define una clase y úsala en múltiples recursos.

```ruby
# app/middleware/auth_middleware.rb
class AuthMiddleware < BugBunny::Middleware::Base
  def on_request(env)
    env.headers['Authorization'] = "Bearer #{ENV['API_KEY']}"
  end
end

# app/models/user.rb
class User < BugBunny::Resource
  client_middleware do |stack|
    stack.use AuthMiddleware
  end
end
```

#### 3. Contexto Dinámico (Pro)
Permite inyectar valores que cambian en cada petición (como el Usuario actual o Tenant), leyendo de variables globales thread-safe (como CurrentAttributes en Rails).

```ruby
# Middleware que lee el Tenant actual
# app/middleware/tenant_middleware.rb
class TenantMiddleware < BugBunny::Middleware::Base
  def on_request(env)
    # Ejemplo usando Rails CurrentAttributes
    if Current.tenant_id
      env.headers['X-Tenant-ID'] = Current.tenant_id
    end
  end
end

class Order < BugBunny::Resource
  client_middleware do |stack|
    stack.use TenantMiddleware
  end
end
```

---

## 📡 Modo Servidor (Worker & Router)

BugBunny incluye un **Router Inteligente** que despacha mensajes a controladores basándose en el Verbo y el Path, imitando a Rails.

### 1. El Controlador (`app/rabbit/controllers/`)

Hereda de `BugBunny::Controller`. Tienes acceso a `params`, `before_action` y `rescue_from`.

```ruby
# app/rabbit/controllers/services_controller.rb
class ServicesController < BugBunny::Controller
  # Callbacks
  before_action :set_service, only: %i[show update destroy]

  # GET services
  def index
    render status: 200, json: DockerService.all
  end

  # POST services
  def create
    # BugBunny wrappea los params automáticamente en el Resource.
    # Aquí los consumimos con seguridad usando Strong Parameters simulados o hash access.
    # params[:service] estará disponible gracias al param_key del Resource.

    result = DockerService.create(params[:service])
    render status: 201, json: result
  end

  private

  def set_service
    # params[:id] se extrae automágicamente de la URL (Route Param)
    @service = DockerService.find(params[:id])

    unless @service
      render status: 404, json: { error: "Service not found" }
    end
  end
end
```

### 2. Manejo de Errores (`rescue_from`)

Puedes definir un `ApplicationController` base para manejar errores de forma centralizada y declarativa.

```ruby
# app/rabbit/controllers/application.rb
class ApplicationController < BugBunny::Controller
  # Manejo específico
  rescue_from ActiveRecord::RecordNotFound do
    render status: :not_found, json: { error: "Resource missing" }
  end

  rescue_from ActiveModel::ValidationError do |e|
    render status: :unprocessable_entity, json: e.model.errors
  end

  # Catch-all (Red de seguridad)
  rescue_from StandardError do |e|
    BugBunny.configuration.logger.error(e)
    render status: :internal_server_error, json: { error: "Internal Error" }
  end
end
```

### 3. Namespace de Controladores (Opcional)

Por defecto, BugBunny busca los controladores dentro del módulo `Rabbit::Controllers`. Esto implica que tus archivos deben estar en `app/rabbit/controllers/`.

Si prefieres organizar tus consumidores en otro lugar (ej: dentro de un dominio específico o carpeta existente), puedes cambiar el namespace.

**Configuración:**
```ruby
# config/initializers/bug_bunny.rb
BugBunny.configure do |config|
  config.controller_namespace = 'Billing::Events'
end
```

### 4. Tabla de Ruteo (Convención)

El Router infiere la acción automáticamente:

| Verbo | URL Pattern | Controlador | Acción |
| :--- | :--- | :--- | :--- |
| `GET` | `services` | `ServicesController` | `index` |
| `GET` | `services/12` | `ServicesController` | `show` |
| `POST` | `services` | `ServicesController` | `create` |
| `PUT` | `services/12` | `ServicesController` | `update` |
| `DELETE` | `services/12` | `ServicesController` | `destroy` |
| `POST` | `services/12/restart` | `ServicesController` | `restart` (Custom) |

### 🔎 Observabilidad y Logging

BugBunny implementa un sistema de **Tracing Distribuido** nativo. Esto permite rastrear una petición desde que se origina en tu aplicación (Producer) hasta que es procesada por el worker (Consumer), manteniendo el mismo ID de traza (`correlation_id`) en todos los logs.

#### 1. Productor: Inyectar el Trace ID

Para asegurar que los mensajes salgan de tu aplicación con el ID de traza correcto (por ejemplo, el `X-Request-Id` de Rails, Sidekiq o tu propio `Current.request_id`), debes inyectarlo antes de publicar el mensaje.

La forma recomendada es crear un Middleware y registrarlo globalmente.

**A. Crear el Middleware**

```ruby
# app/middleware/correlation_injector.rb
class CorrelationInjector < BugBunny::Middleware::Base
  def on_request(env)
    # Ejemplo: Si usas Rails CurrentAttributes o similar
    if defined?(Current) && Current.request_id
      env.correlation_id = Current.request_id
    end
  end
end
```

**B. Registrar el Middleware (Initializer)**

```ruby
# config/initializers/bug_bunny.rb
require 'bug_bunny'
require_relative '../../app/middleware/correlation_injector'

# Módulo para interceptar la inicialización de cualquier cliente
module BugBunnyGlobalMiddleware
  def initialize(pool:)
    super
    @stack.use CorrelationInjector
  end
end

# Aplicamos el parche para que afecte a Resources y Clientes manuales
BugBunny::Client.prepend(BugBunnyGlobalMiddleware)
```

---

#### 2. Consumidor: Logging Automático

El consumidor de BugBunny está diseñado para garantizar la trazabilidad "out-of-the-box".

##### A. Comportamiento por Defecto
Al recibir un mensaje, el Consumidor realiza automáticamente los siguientes pasos:
1. Extrae el `correlation_id` de las propiedades AMQP (o genera un UUID si no existe).
2. Envuelve todo el procesamiento en un bloque de log etiquetado (`tagged logging`).
3. Pasa el ID al Controlador.

**No necesitas configurar nada.** Tus logs se verán así automáticamente:

```text
[d41d8cd9-8f00...] [Consumer] Listening on queue...
[d41d8cd9-8f00...] [API] Procesando usuario 123...
```

##### B. Configuración Global (Initializer)
Si deseas agregar tags estáticos que aparezcan en **todos** los mensajes procesados por este worker (como el nombre del servicio, versión o entorno), agrégalos a `config.log_tags`.

> **Nota:** No agregues `:uuid` aquí, ya que el Consumidor lo agrega automáticamente.

```ruby
BugBunny.configure do |config|
  # ... configuración de conexión ...

  # Tags globales adicionales
  config.log_tags = [
    'WORKER',
    ->(_) { ENV['APP_VERSION'] }
  ]
end
```

**Resultado en Log:**
```text
[d41d8cd9...] [WORKER] [v1.0.2] [API] Procesando mensaje...
```

##### C. Configuración por Controlador (Contexto Rico)
Para agregar información específica del mensaje o lógica de negocio (como IDs de inquilinos, usuario actual, o headers específicos), utiliza `self.log_tags` en tus controladores.

Esto aprovecha el `around_action` nativo de la gema para inyectar contexto.

```ruby
# app/rabbit/controllers/application_controller.rb
module Rabbit
  module Controllers
    class ApplicationController < BugBunny::Controller
      # Define tags dinámicos basados en el mensaje actual
      self.log_tags = [
        ->(c) { c.params[:tenant_id] },      # Tag del Tenant (si viene en el body)
        ->(c) { c.headers['X-Source'] }      # Tag del origen
      ]
    end
  end
end
```

**Resultado Final en Log:**
(UUID Automático + Tag Global + Tag de Controlador)
```text
[d41d8cd9...] [WORKER] [Tenant-55] [Console] Creando usuario...
```

---

## 🔌 Modo Publisher (Cliente Manual)

Si necesitas enviar mensajes crudos fuera de la lógica Resource, usa `BugBunny::Client`.

```ruby
client = BugBunny::Client.new(pool: BUG_BUNNY_POOL)

# --- REQUEST (Síncrono / RPC) ---
# Espera la respuesta. Lanza BugBunny::RequestTimeout si falla.
response = client.request('services/123/logs',
  method: :get,
  exchange: 'logs_exchange',
  timeout: 5
)
puts response['body']

# --- PUBLISH (Asíncrono / Fire-and-Forget) ---
# No espera respuesta.
client.publish('audit/events',
  method: :post,
  body: { event: 'login', user_id: 1 }
)
```

### ⚠️ Consideraciones sobre RPC (Direct Reply-To)

BugBunny utiliza el mecanismo nativo `amq.rabbitmq.reply-to` para las peticiones RPC. Esto maximiza el rendimiento eliminando la necesidad de crear colas temporales por cada petición.

**Trade-off:**
Al usar este mecanismo, las respuestas son efímeras. Si el proceso Cliente (tu aplicación Rails/Sidekiq) se reinicia abruptamente justo después de enviar la petición pero milisegundos antes de procesar la respuesta, **esa respuesta se perderá**.

**Recomendación:**
Diseña tus acciones de Controlador RPC (`POST`, `PUT`) para que sean **idempotentes**.
* *Mal diseño:* "Crear pago" (si se reintenta, cobra doble).
* *Buen diseño:* "Crear pago con ID X" (si se reintenta y ya existe, devuelve el recibo existente).

Esto permite que, ante un `BugBunny::RequestTimeout` por caída del cliente, puedas reintentar la operación de forma segura.

---

## 🏗 Arquitectura REST-over-AMQP

BugBunny desacopla el transporte de la lógica usando headers estándar.

1.  **Semántica:** El mensaje lleva headers `type` (URL) y `x-http-method` (Verbo).
2.  **Ruteo:** El consumidor lee estos headers y ejecuta el controlador correspondiente.
3.  **Parametros:** `params` unifica:
    * **Route Params:** `services/123` -> `params[:id] = 123`
    * **Query Params:** `services?force=true` -> `params[:force] = true`
    * **Body:** Payload JSON fusionado en el hash.

### Logs Estructurados

Facilita el debugging mostrando claramente qué recurso se está tocando y por dónde viaja.

```text
[BugBunny] [POST] '/services' | Exchange: 'cluster' (Type: direct) | Routing Key: 'node-1'
```

---

## 📄 Licencia

Código abierto bajo [MIT License](https://opensource.org/licenses/MIT).
