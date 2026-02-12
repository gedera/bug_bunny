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
  config.logger = Logger.new(STDOUT)
  config.logger.level = Logger::INFO

  # Logger de Bunny (Driver): Silencia el ruido de bajo nivel (WARN)
  config.bunny_logger = Logger.new(STDOUT)
  config.bunny_logger.level = Logger::WARN
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

### 3. Tabla de Ruteo (Convención)

El Router infiere la acción automáticamente:

| Verbo | URL Pattern | Controlador | Acción |
| :--- | :--- | :--- | :--- |
| `GET` | `services` | `ServicesController` | `index` |
| `GET` | `services/12` | `ServicesController` | `show` |
| `POST` | `services` | `ServicesController` | `create` |
| `PUT` | `services/12` | `ServicesController` | `update` |
| `DELETE` | `services/12` | `ServicesController` | `destroy` |
| `POST` | `services/12/restart` | `ServicesController` | `restart` (Custom) |

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
