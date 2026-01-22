# 🐰 BugBunny

**BugBunny** es un framework de comunicación RPC para Ruby on Rails sobre **RabbitMQ**.

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

Define modelos que actúan como proxis de recursos remotos. BugBunny se encarga de construir la "URL" y la Routing Key automáticamente siguiendo convenciones REST.

### 1. Definir el Modelo

```ruby
# app/models/remote_user.rb
class RemoteUser < BugBunny::Resource
  # Configuración de RabbitMQ
  self.exchange = 'users.topic'
  self.exchange_type = 'topic'
  self.routing_key_prefix = 'users'

  # Atributos (ActiveModel)
  attribute :id, :integer
  attribute :name, :string
  attribute :email, :string
  attribute :active, :boolean

  # Validaciones (se ejecutan antes de viajar a la red)
  validates :email, presence: true
end
```

### 2. Consumir el Servicio (CRUD)

La API simula ActiveRecord, pero por debajo envía mensajes RPC con headers tipo URL para enrutamiento inteligente.

```ruby
# --- READ (Colección con Filtros) ---
# Genera Header type: "remote_users/index?active=true&role=admin"
# Genera Routing Key: "users.index"
users = RemoteUser.where(active: true, role: 'admin')

# --- READ (Singular) ---
# Genera Header type: "remote_users/show/123"
# Genera Routing Key: "users.show.123"
user = RemoteUser.find(123)

# --- CREATE ---
# Genera Header type: "remote_users/create" (Body JSON con datos)
user = RemoteUser.create(name: "Nuevo", email: "test@test.com")
puts user.persisted? # => true

# --- UPDATE ---
# Genera Header type: "remote_users/update/123"
user.update(name: "Editado") 
# Solo envía los atributos modificados (Dirty Tracking)

# --- DESTROY ---
# Genera Header type: "remote_users/destroy/123"
user.destroy
```

### 3. Override Temporal (`.with`)

Thread-safe para entornos concurrentes (Sidekiq/Puma).

```ruby
# Usar otro exchange solo para esta llamada
RemoteUser.with(exchange: 'legacy_exchange').find(99)
```

---

## 📡 Modo Servidor (El Worker)

BugBunny incluye un **Router Inteligente** que parsea el header `type` del mensaje entrante, extrae el ID y los Query Params (usando `URI`), e invoca al controlador correspondiente.

### 1. Definir Controladores

Crea tus controladores en `app/rabbit/controllers/`. Heredan de `BugBunny::Controller`.

```ruby
# app/rabbit/controllers/remote_users_controller.rb
class RemoteUsersController < BugBunny::Controller

  # Acción para type: "remote_users/index?active=true"
  def index
    # params[:active] viene del Query String de la URL
    users = User.where(active: params[:active])
    render status: 200, json: users
  end

  # Acción para type: "remote_users/show/12"
  def show
    # params[:id] se extrae automáticamente del Path de la URL
    user = User.find_by(id: params[:id])

    if user
      render status: 200, json: user
    else
      render status: 404, json: { error: 'Not Found' }
    end
  end

  # Acción para type: "remote_users/create"
  def create
    # params fusiona el Body JSON + Query Params + ID
    user = User.new(params)

    if user.save
      render status: 201, json: user
    else
      render status: 422, json: { errors: user.errors }
    end
  end
end
```

### 2. Ejecutar el Worker

BugBunny incluye una tarea Rake que levanta los consumidores configurados.

```bash
bundle exec rake bug_bunny:work
```

---

## 🔌 Modo Publisher Manual

Si necesitas enviar mensajes crudos sin usar `Resource` (ej: eventos fire-and-forget), puedes usar el Cliente directamente.

```ruby
client = BugBunny::Client.new(pool: BUG_BUNNY_POOL)

# Enviar una alerta (Fire-and-Forget)
# Respetamos la convención de URL en el 'type' para que el router lo entienda
client.publish('alerts/create', exchange: 'notifications', routing_key: 'alerts.critical') do |req|
  req.body = { message: "CPU High", server: "web-1" }
end

# Petición RPC Manual
response = client.request('users/index?role=admin', exchange: 'users', routing_key: 'users.index')
puts response['body'] # Array de usuarios
```

---

## 🏗 Arquitectura REST-over-AMQP

BugBunny mapea conceptos de HTTP/REST a AMQP 0.9.1 para estandarizar la comunicación entre microservicios:

| Concepto | REST (HTTP) | BugBunny (AMQP) |
| :--- | :--- | :--- |
| **Endpoint** | URL Path (`/users/1`) | Header `type` (`users/show/1`) |
| **Filtros** | Query String (`?active=true`) | Header `type` (`users/index?active=true`) |
| **Verbo** | GET, POST, PUT, DELETE | Routing Key (`users.show`, `users.create`) |
| **Payload** | Body (JSON) | Body (JSON) |
| **Status** | HTTP Status Code (200, 404) | JSON Response `status` key |

---

## 🛠 Middlewares

BugBunny usa una arquitectura de pila (Stack) para procesar peticiones y respuestas.

```ruby
BugBunny::Client.new(pool: POOL) do |conn|
  # 1. Convierte errores 4xx/5xx en Excepciones Ruby
  conn.use BugBunny::Middleware::RaiseError

  # 2. Parsea JSON string a HashWithIndifferentAccess
  conn.use BugBunny::Middleware::JsonResponse
end
```

### Excepciones Principales

* `BugBunny::UnprocessableEntity` (422): Error de validación.
* `BugBunny::NotFound` (404): Recurso no encontrado.
* `BugBunny::RequestTimeout`: El servidor demoró más de `rpc_timeout`.
* `BugBunny::CommunicationError`: RabbitMQ no disponible.

---

## 📄 Licencia

Código abierto bajo [MIT License](https://opensource.org/licenses/MIT).
