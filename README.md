# 🐰 BugBunny

**BugBunny** es un framework RPC para Ruby on Rails sobre **RabbitMQ**.

Su filosofía es **"Active Record over AMQP"**. Abstrae la complejidad de colas y exchanges transformando patrones de mensajería en una arquitectura **RESTful simulada**, donde los mensajes contienen "URLs" y "Query Params" que son enrutados automáticamente a controladores.

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

Corre el instalador para generar la configuración:

```bash
rails g bug_bunny:install
```

---

## ⚙️ Configuración

Configura tus credenciales y el Pool de conexiones en el inicializador.

```ruby
# config/initializers/bug_bunny.rb

BugBunny.configure do |config|
  config.host     = ENV.fetch('RABBITMQ_HOST', 'localhost')
  config.username = ENV.fetch('RABBITMQ_USER', 'guest')
  config.password = ENV.fetch('RABBITMQ_PASS', 'guest')
  config.vhost    = ENV.fetch('RABBITMQ_VHOST', '/')

  # Timeouts y Recuperación
  config.rpc_timeout = 10       # Segundos a esperar respuesta síncrona
  config.network_recovery_interval = 5
end

# Definimos el Pool Global (Vital para Puma/Sidekiq)
BUG_BUNNY_POOL = ConnectionPool.new(size: ENV.fetch('RAILS_MAX_THREADS', 5).to_i, timeout: 5) do
  BugBunny.create_connection
end

# Inyectamos el pool por defecto a los recursos
BugBunny::Resource.connection_pool = BUG_BUNNY_POOL
```

---

## 🚀 Modo Resource (El Cliente)

Define modelos que actúan como proxis de recursos remotos. BugBunny separa la **Lógica de Transporte** (RabbitMQ) de la **Lógica de Aplicación** (Controladores).

### Escenario A: Routing Dinámico (Topic / Estándar)
Ideal cuando quieres enrutar por acción. La Routing Key se genera automáticamente usando `resource_name.action`.

```ruby
class RemoteUser < BugBunny::Resource
  # --- Configuración ---
  self.exchange = 'app.topic'
  self.exchange_type = 'topic'

  # Define el nombre lógico del recurso.
  # 1. Routing Key: 'users.create', 'users.show.12'
  # 2. Header Type: 'users/create', 'users/show/12'
  self.resource_name = 'users'

  attribute :id, :integer
  attribute :email, :string
end
```

### Escenario B: Routing Estático (Direct / Cola Dedicada)
Ideal cuando quieres enviar todo a una cola específica (ej: un Manager), independientemente de la acción.

```ruby
class BoxManager < BugBunny::Resource
  # --- Configuración ---
  self.exchange = 'warehouse.direct'
  self.exchange_type = 'direct'

  # FORZAMOS LA ROUTING KEY.
  # Todo viaja con esta key, sin importar la acción.
  self.routing_key = 'manager_queue'

  # Define el nombre lógico para el Controlador.
  # Header Type: 'box_manager/create', 'box_manager/show/12'
  self.resource_name = 'box_manager'

  attribute :id, :integer
  attribute :status, :string
end
```

### Consumiendo el Servicio (CRUD)

La API simula ActiveRecord. Por debajo, construye una "URL" en el header `type` para que el consumidor sepa qué hacer.

```ruby
# --- READ (Colección con Filtros) ---
# Header Type: "users/index?active=true" (Query Params)
# Routing Key: "users.index" (Dinámico) o "manager_queue" (Estático)
users = RemoteUser.where(active: true)

# --- READ (Singular) ---
# Header Type: "users/show/123" (ID en Path)
# Routing Key: "users.show.123" (Dinámico) o "manager_queue" (Estático)
user = RemoteUser.find(123)

# --- CREATE ---
# Header Type: "users/create"
user = RemoteUser.create(email: "test@test.com")

# --- UPDATE ---
# Header Type: "users/update/123"
user.update(email: "edit@test.com") 
# Dirty Tracking: Solo se envían los atributos modificados.

# --- DESTROY ---
# Header Type: "users/destroy/123"
user.destroy
```

### Override Temporal (`.with`)
Thread-safe. Útil para cambiar configuración en tiempo de ejecución.

```ruby
# Enviar este mensaje a una cola específica solo por esta vez
RemoteUser.with(routing_key: 'urgent_queue').create(email: 'vip@test.com')
```

---

## 📡 Modo Servidor (El Worker)

BugBunny incluye un **Router Inteligente** que parsea el header `type` (la URL simulada), extrae parámetros y despacha al controlador.

### 1. Definir Controladores

Crea tus controladores en `app/rabbit/controllers/`. Heredan de `BugBunny::Controller`.

```ruby
# app/rabbit/controllers/users_controller.rb
class UsersController < BugBunny::Controller

  # Acción para type: "users/index?active=true"
  def index
    # params fusiona Query Params y Body
    users = User.where(active: params[:active])
    render status: 200, json: users
  end

  # Acción para type: "users/show/12"
  def show
    # params[:id] se extrae automáticamente del Path de la URL
    user = User.find_by(id: params[:id])

    if user
      render status: 200, json: user
    else
      render status: 404, json: { error: 'Not Found' }
    end
  end

  # Acción para type: "users/create"
  def create
    user = User.new(params)
    if user.save
      render status: 201, json: user
    else
      # Estos errores se propagan como BugBunny::UnprocessableEntity
      render status: 422, json: { errors: user.errors }
    end
  end
end
```

### 2. Ejecutar el Worker

```bash
bundle exec rake bug_bunny:work
```

---

## 🏗 Arquitectura REST-over-AMQP

BugBunny desacopla el transporte de la lógica usando headers.

| Concepto | REST (HTTP) | BugBunny (AMQP) | Configuración |
| :--- | :--- | :--- | :--- |
| **Endpoint** | URL Path (`/users/1`) | Header `type` (`users/show/1`) | `resource_name` |
| **Filtros** | Query String (`?active=true`) | Header `type` (`users/index?active=true`) | Automático (`where`) |
| **Destino Físico** | IP/Dominio | Routing Key (`users.create` o `manager`) | `routing_key` (Estático) o `resource_name` (Dinámico) |
| **Payload** | Body (JSON) | Body (JSON) | N/A |
| **Status** | HTTP Code (200, 404) | JSON Response `status` | N/A |

---

## 🛠 Middlewares

BugBunny usa una pila de middlewares para procesar respuestas.

```ruby
BugBunny::Client.new(pool: POOL) do |conn|
  # 1. Lanza excepciones Ruby para errores 4xx/5xx
  conn.use BugBunny::Middleware::RaiseError

  # 2. Parsea JSON a HashWithIndifferentAccess
  conn.use BugBunny::Middleware::JsonResponse
end
```

### Excepciones

* `BugBunny::UnprocessableEntity` (422): Error de validación.
* `BugBunny::NotFound` (404): Recurso no encontrado.
* `BugBunny::RequestTimeout`: Timeout RPC.
* `BugBunny::CommunicationError`: Fallo de red RabbitMQ.

---

## 📄 Licencia

Código abierto bajo [MIT License](https://opensource.org/licenses/MIT).
