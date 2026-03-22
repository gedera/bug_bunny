# 🐰 BugBunny

[![Gem Version](https://badge.fury.io/rb/bug_bunny.svg)](https://badge.fury.io/rb/bug_bunny)

**Active Record over AMQP.**

BugBunny transforma la complejidad de la mensajería asíncrona (RabbitMQ) en una arquitectura **RESTful familiar** para desarrolladores Rails. Envía mensajes como si estuvieras usando Active Record y procésalos como si fueran Controladores de Rails, apoyado por un potente motor de enrutamiento declarativo.

---

## 📖 Tabla de Contenidos
- [Introducción: La Filosofía](#-introducción-la-filosofía)
- [Instalación](#-instalación)
- [Configuración Inicial](#-configuración-inicial)
- [Configuración de Infraestructura en Cascada](#-configuración-de-infraestructura-en-cascada)
- [Modo Cliente: Recursos (ORM)](#-modo-cliente-recursos-orm)
    - [Definición y Atributos](#1-definición-y-atributos-híbridos)
    - [CRUD y Consultas](#2-crud-y-consultas-restful)
    - [Contexto Dinámico (.with)](#3-contexto-dinámico-with)
    - [Client Middleware](#4-client-middleware-interceptores)
- [Modo Servidor: Controladores](#-modo-servidor-controladores)
    - [Ruteo Declarativo (Rutas)](#1-ruteo-declarativo-rutas)
    - [El Controlador](#2-el-controlador)
    - [Manejo de Errores](#3-manejo-de-errores-declarativo)
- [Observabilidad y Tracing](#-observabilidad-y-tracing)
- [Guía de Producción](#-guía-de-producción)

---

## 💡 Introducción: La Filosofía

En lugar de pensar en "Exchanges" y "Queues", BugBunny inyecta verbos HTTP (`GET`, `POST`, `PUT`, `DELETE`) y rutas (`users/1`) en los headers de AMQP.

* **Tu código (Cliente):** `User.create(name: 'Gabi')`
* **Protocolo (BugBunny):** Envía `POST /users` (Header `type: users`) vía RabbitMQ.
* **Worker (Servidor):** Recibe el mensaje, evalúa tu mapa de rutas y ejecuta `UsersController#create`.

---

## 📦 Instalación

Agrega la gema a tu `Gemfile`:

```ruby
gem 'bug_bunny', '~> 4.0'
```

Ejecuta el bundle e instala los archivos base:

```bash
bundle install
rails g bug_bunny:install
```

Esto genera:
1.  `config/initializers/bug_bunny.rb`
2.  `app/rabbit/controllers/`

---

## ⚙️ Configuración Inicial

Para entornos productivos (Puma/Sidekiq), es **obligatorio** configurar un Pool de conexiones.

```ruby
# config/initializers/bug_bunny.rb

BugBunny.configure do |config|
  # 1. Credenciales
  config.host     = ENV.fetch('RABBITMQ_HOST', 'localhost')
  config.username = ENV.fetch('RABBITMQ_USER', 'guest')
  config.password = ENV.fetch('RABBITMQ_PASS', 'guest')
  config.vhost    = ENV.fetch('RABBITMQ_VHOST', '/')

  # 2. Timeouts y Recuperación
  config.rpc_timeout = 10               # Segundos máx para esperar respuesta (Síncrono)
  config.network_recovery_interval = 5  # Reintento de conexión

  # 3. Health Checks (Opcional, para Docker Swarm / K8s)
  config.health_check_file = '/tmp/bug_bunny_health'

  # 4. Logging
  config.logger = Rails.logger
end

# 5. Connection Pool (CRÍTICO para concurrencia)
# Define un pool global para compartir conexiones entre hilos
BUG_BUNNY_POOL = ConnectionPool.new(size: ENV.fetch('RAILS_MAX_THREADS', 5).to_i, timeout: 5) do
  BugBunny.create_connection
end

# Inyecta el pool en los recursos
BugBunny::Resource.connection_pool = BUG_BUNNY_POOL
```

---

## 🏗️ Configuración de Infraestructura en Cascada

BugBunny utiliza un sistema de configuración jerárquico para los parámetros de RabbitMQ (como la durabilidad de Exchanges y Colas). Las opciones se resuelven en el siguiente orden de prioridad:

1.  **Defaults de la Gema:** Rápidos y efímeros (`durable: false`).
2.  **Configuración Global:** Definida en el inicializador para todo el entorno.
3.  **Configuración de Recurso:** Atributos de clase en modelos específicos.
4.  **Configuración al Vuelo:** Parámetros pasados en la llamada `.with` o en el Cliente manual.

**Ejemplo de Configuración Global (Nivel 2):**
Útil para hacer que todos los recursos en el entorno de pruebas sean auto-borrables.

```ruby
# config/initializers/bug_bunny.rb
BugBunny.configure do |config|
  if Rails.env.test?
    config.exchange_options = { auto_delete: true }
    config.queue_options    = { auto_delete: true }
  end
end
```

---

## 🚀 Modo Cliente: Recursos (ORM)

Los recursos son proxies de servicios remotos. Heredan de `BugBunny::Resource`.

### 1. Definición y Atributos Híbridos
BugBunny es **Schema-less**. Soporta atributos tipados (ActiveModel) y dinámicos simultáneamente, además de definir su propia infraestructura.

```ruby
# app/models/manager/service.rb
class Manager::Service < BugBunny::Resource
  # Configuración de Transporte
  self.exchange = 'cluster_events'
  self.exchange_type = 'topic'

  # Configuración de Infraestructura Específica (Nivel 3)
  # Este recurso crítico sobrevivirá a reinicios del servidor RabbitMQ
  self.exchange_options = { durable: true, auto_delete: false }

  # Configuración de Ruteo (La "URL" base)
  self.resource_name = 'services'

  # A. Atributos Tipados (Opcional, para casting)
  attribute :created_at, :datetime
  attribute :replicas, :integer, default: 1

  # B. Validaciones (Funcionan en ambos tipos)
  validates :name, presence: true
end
```

### 2. CRUD y Consultas RESTful

```ruby
# --- LEER (GET) ---
# RPC: Espera respuesta del worker.
# Envia: GET services/123
service = Manager::Service.find('123')

# --- BÚSQUEDAS AVANZADAS ---
# Soporta Hashes anidados para filtros complejos.
# Envia: GET services?q[status]=active&q[tags][]=web
Manager::Service.where(q: { status: 'active', tags: ['web'] })

# --- CREAR (POST) ---
# RPC: Envía payload y espera el objeto persistido.
# Payload: { "service": { "name": "nginx", "replicas": 3 } }
svc = Manager::Service.create(name: 'nginx', replicas: 3)

# --- ACTUALIZAR (PUT) ---
# Dirty Tracking: Solo envía los campos que cambiaron.
svc.name = 'nginx-pro'
svc.save

# --- ELIMINAR (DELETE) ---
svc.destroy
```

### 3. Contexto Dinámico (`.with`)
Puedes sobrescribir la configuración de enrutamiento o infraestructura para una ejecución específica sin afectar al modelo global (Thread-Safe).

```ruby
# Nivel 4: Configuración al vuelo. Inyectamos opciones solo para esta llamada.
Manager::Service.with(
  routing_key: 'high_priority',
  exchange_options: { durable: false } # Ignora el durable: true de la clase
).create(name: 'redis_temp')
```

### 4. Client Middleware (Interceptores)
Intercepta peticiones de ida y respuestas de vuelta en la arquitectura del cliente.

**Middlewares Incluidos (Built-ins)**
Si usas `BugBunny::Resource`, el manejo de JSON y de errores ya está integrado automáticamente. Pero si utilizas el cliente manual (`BugBunny::Client`), puedes inyectar los middlewares incluidos para no tener que parsear respuestas manualmente:

* `BugBunny::Middleware::JsonResponse`: Parsea automáticamente el cuerpo de la respuesta de JSON a un Hash de Ruby.
* `BugBunny::Middleware::RaiseError`: Evalúa el código de estado (`status`) de la respuesta y lanza excepciones nativas (`BugBunny::NotFound`, `BugBunny::UnprocessableEntity`, `BugBunny::InternalServerError`, etc.).

```ruby
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

# 3. Métodos de conveniencia (Atajos)
client.request('users/1') # Siempre :rpc
client.publish('events', body: { type: 'click' }) # Siempre :publish

# Ahora el cliente devolverá Hashes y lanzará errores si el worker falla
response = client.request('users/1', method: :get)
```

**Middlewares Personalizados**
Ideales para inyectar Auth o Headers de trazabilidad en todos los requests de un Recurso.

```ruby
class Manager::Service < BugBunny::Resource
  client_middleware do |stack|
    stack.use(Class.new(BugBunny::Middleware::Base) do
      def on_request(env)
        env.headers['Authorization'] = "Bearer #{ENV['API_TOKEN']}"
        env.headers['X-App-Version'] = '1.0.0'
      end
    end)
  end
end
```

**Personalización Avanzada de Errores**
Si en tu aplicación necesitas mapear códigos HTTP de negocio (ej. `402 Payment Required`) a excepciones personalizadas, la forma más limpia es usar `Module#prepend` sobre el middleware nativo en un inicializador. De esta forma inyectas tus reglas sin perder el comportamiento por defecto para los demás errores:

```ruby
# config/initializers/bug_bunny_custom_errors.rb
module CustomBugBunnyErrors
  def on_complete(response)
    status = response['status'].to_i

    # 1. Reglas específicas de tu negocio
    if status == 402
      raise MyApp::PaymentRequiredError, response['body']['message']
    elsif status == 403 && response['body']['reason'] == 'ip_blocked'
      raise MyApp::IpBlockedError, response['body']['detail']
    end

    # 2. Delegar el resto de los errores (404, 422, 500) al middleware original
    super(response)
  end
end

BugBunny::Middleware::RaiseError.prepend(CustomBugBunnyErrors)
```

---

## 📡 Modo Servidor: Controladores

A partir de BugBunny v4, el enrutamiento es **declarativo** y explícito, al igual que en Rails. Se utiliza un archivo de rutas centralizado para mapear los mensajes AMQP entrantes a los Controladores adecuados.

### 1. Ruteo Declarativo (Rutas)
Crea un inicializador en tu aplicación (ej. `config/initializers/bug_bunny_routes.rb`) para definir tu mapa de rutas. BugBunny usará este DSL para extraer automáticamente parámetros dinámicos de las URLs.

```ruby
# config/initializers/bug_bunny_routes.rb

BugBunny.routes.draw do
  # 1. Colecciones Básicas y Filtrado
  # Genera rutas para index, show y update únicamente
  resources :services, only: [:index, :show, :update]

  # 2. Rutas Anidadas (Member y Collection)
  resources :nodes, except: [:create, :destroy] do
    # Member inyecta el parámetro :id (ej. PUT nodes/:id/drain)
    member do
      put :drain
      post :restart
    end

    # Collection opera sobre el conjunto (ej. GET nodes/stats)
    collection do
      get :stats
    end
  end

  # 3. Rutas estáticas (Colecciones o Acciones Custom)
  get 'health_checks/up', to: 'health_checks#up'

  # 4. Extracción automática de variables dinámicas profundas
  get 'api/v1/clusters/:cluster_id/nodes/:node_id/metrics', to: 'api/v1/metrics#show'
end
```

### 2. El Controlador
Ubicación: `app/rabbit/controllers/`.
Los parámetros declarados en el archivo de rutas (como `:id` o `:cluster_id`) estarán disponibles automáticamente dentro del hash `params` de tu controlador.

```ruby
class ServicesController < BugBunny::Controller
  # Callbacks estándar
  before_action :set_service, only: [:show, :update]

  def show
    # Renderiza JSON que viajará de vuelta por la cola reply-to
    render status: 200, json: { id: @service.id, state: 'running' }
  end

  def create
    # BugBunny envuelve los params automáticamente basándose en el resource_name
    # params[:service] => { name: '...', replicas: ... }
    if Service.create(params[:service])
      render status: 201, json: { status: 'created' }
    else
      render status: 422, json: { errors: 'Invalid' }
    end
  end

  private

  def set_service
    # params[:id] es extraído e inyectado por el BugBunny.routes
    @service = Service.find(params[:id])
  end
end
```

### 3. Manejo de Errores Declarativo
Captura excepciones y devuélvelas como códigos de estado AMQP/HTTP.

```ruby
class ApplicationController < BugBunny::Controller
  rescue_from ActiveRecord::RecordNotFound do |e|
    render status: :not_found, json: { error: "Resource missing" }
  end

  rescue_from StandardError do |e|
    BugBunny.configuration.logger.error(e)
    render status: :internal_server_error, json: { error: "Crash" }
  end
end
```

---

## 🔎 Observabilidad y Tracing

BugBunny implementa Distributed Tracing nativo. El `correlation_id` se mantiene intacto a través de toda la cadena: `Producer -> RabbitMQ -> Consumer -> Controller`.

### 1. Logs Automáticos (Consumer)
No requiere configuración. El worker envuelve la ejecución en bloques de log etiquetados con el UUID.

```text
[d41d8cd9...] [BugBunny::Consumer] 📥 Received PUT "/nodes/4bv445vgc158hk" | RK: 'dbu55...'
[d41d8cd9...] [BugBunny::Consumer] 🎯 Routed to Rabbit::Controllers::NodesController#drain
```

### 2. Logs de Negocio (Controller)
Inyecta contexto rico (Tenant, Usuario, IP) en los logs usando `log_tags`.

```ruby
# app/rabbit/controllers/application_controller.rb
class ApplicationController < BugBunny::Controller
  self.log_tags = [
    ->(c) { c.params[:tenant_id] }, # Agrega [Tenant-55]
    ->(c) { c.headers['X-Source'] } # Agrega [Console]
  ]
end
```

### 3. Inyección en el Productor
Para que tus logs de Rails y Rabbit coincidan, usa un middleware global:

```ruby
# config/initializers/bug_bunny.rb
# Middleware para inyectar Current.request_id de Rails al mensaje Rabbit
class CorrelationInjector < BugBunny::Middleware::Base
  def on_request(env)
    env.correlation_id = Current.request_id if defined?(Current)
  end
end

BugBunny::Client.prepend(Module.new {
  def initialize(pool:)
    super
    @stack.use CorrelationInjector
  end
})
```

---

## 🧵 Guía de Producción

### Connection Pooling
Es vital usar `ConnectionPool` si usas servidores web multi-hilo (Puma) o workers (Sidekiq). BugBunny no gestiona hilos internamente; se apoya en el pool.

### Fork Safety
BugBunny incluye un `Railtie` que detecta automáticamente cuando Rails hace un "Fork" (ej: Puma en modo Cluster o Spring). Desconecta automáticamente las conexiones heredadas para evitar corrupción de datos en los sockets TCP.

### RPC y "Direct Reply-To"
Para máxima velocidad, BugBunny usa `amq.rabbitmq.reply-to`.
* **Trade-off:** Si el cliente (Rails) se reinicia justo después de enviar un mensaje RPC pero antes de recibir la respuesta, esa respuesta se pierde.
* **Recomendación:** Diseña tus acciones RPC (`POST`, `PUT`) para que sean **idempotentes** (seguras de reintentar ante un timeout).

### Seguridad
El Router incluye protecciones contra **Remote Code Execution (RCE)**. El Consumer verifica estrictamente que el Controlador resuelto a través del archivo de rutas herede de `BugBunny::Controller` antes de ejecutarla, impidiendo la inyección de clases arbitrarias. Además, las llamadas a rutas no registradas fallan rápido con un `404 Not Found`.

### Health Checks en Docker Swarm / Kubernetes
Dado que un Worker se ejecuta en segundo plano sin exponer un servidor web tradicional, orquestadores como Docker Swarm o Kubernetes no pueden usar un endpoint HTTP para verificar si el proceso está saludable.

BugBunny implementa el patrón **Touchfile**. Puedes configurar la gema para que actualice la fecha de modificación de un archivo temporal en cada latido exitoso (heartbeat) hacia RabbitMQ.

**1. Configurar la gema:**
```ruby
# config/initializers/bug_bunny.rb
BugBunny.configure do |config|
  # Actualizará la fecha de este archivo si la conexión a la cola está sana
  config.health_check_file = '/tmp/bug_bunny_health'
end
```

**2. Configurar el Orquestador (Ejemplo docker-compose.yml):**
Con esta configuración, Docker Swarm verificará que el archivo haya sido modificado (tocado) en los últimos 15 segundos. Si el worker se bloquea o pierde la conexión de manera irrecuperable, Docker reiniciará el contenedor automáticamente.

```yaml
services:
  worker:
    image: my_rails_app
    command: bundle exec rake bug_bunny:work
    healthcheck:
      test: ["CMD-SHELL", "test $$(expr $$(date +%s) - $$(stat -c %Y /tmp/bug_bunny_health)) -lt 15 || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 3
```

---

## 📄 Licencia

Código abierto bajo [MIT License](https://opensource.org/licenses/MIT).
