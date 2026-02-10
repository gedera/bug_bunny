# 🐰 BugBunny

**BugBunny** es un framework RPC para Ruby on Rails sobre **RabbitMQ**.

Su filosofía es **"Active Record over AMQP"**. Abstrae la complejidad de colas y exchanges transformando patrones de mensajería en una arquitectura **RESTful simulada**.

A diferencia de otros clientes de RabbitMQ, BugBunny viaja con **Verbos HTTP** (`GET`, `POST`, `PUT`, `DELETE`) inyectados en los headers AMQP. Esto permite construir una API semántica donde un **Router Inteligente** despacha los mensajes a controladores Rails estándar.

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

Corre el instalador para generar la configuración inicial:

```bash
rails g bug_bunny:install
```

---

## ⚙️ Configuración

Configura tus credenciales y el Pool de conexiones en el inicializador `config/initializers/bug_bunny.rb`.

```ruby
BugBunny.configure do |config|
  config.host     = ENV.fetch('RABBITMQ_HOST', 'localhost')
  config.username = ENV.fetch('RABBITMQ_USER', 'guest')
  config.password = ENV.fetch('RABBITMQ_PASS', 'guest')
  config.vhost    = ENV.fetch('RABBITMQ_VHOST', '/')

  # Timeouts y Recuperación
  config.rpc_timeout = 10       # Segundos a esperar respuesta síncrona
  config.network_recovery_interval = 5
end

# ⚠️ CRÍTICO: Definimos el Pool Global
# Es vital usar ConnectionPool para garantizar la seguridad en entornos
# multi-hilo como Puma o Sidekiq.
BUG_BUNNY_POOL = ConnectionPool.new(size: ENV.fetch('RAILS_MAX_THREADS', 5).to_i, timeout: 5) do
  BugBunny.create_connection
end

# Inyectamos el pool por defecto a los recursos
BugBunny::Resource.connection_pool = BUG_BUNNY_POOL
```

---

## 🚀 Modo Resource (ORM / Active Record)

Define modelos que actúan como proxies de recursos remotos. BugBunny separa la **Lógica de Transporte** (RabbitMQ) de la **Lógica de Aplicación** (Controladores).

### Definición del Modelo

```ruby
class RemoteUser < BugBunny::Resource
  # 1. Configuración de Transporte
  self.exchange = 'app.topic'
  self.exchange_type = 'topic'
  
  # 2. Configuración Lógica (Routing)
  # Define el nombre del recurso. Se usa para:
  # - Routing Key automática: 'users' (Topic)
  # - URL Base: 'users'
  self.resource_name = 'users'

  # Nota: BugBunny es Schema-less. No necesitas definir atributos.
  # Soporta acceso dinámico: user.Name, user.email, etc.
end
```

### Consumiendo el Servicio (CRUD RESTful)

BugBunny traduce automáticamente las llamadas de Ruby a peticiones HTTP simuladas.

```ruby
# --- READ COLLECTION (Index) ---
# Envia: GET users?active=true
# Routing Key: "users"
users = RemoteUser.where(active: true)

# --- READ MEMBER (Show) ---
# Envia: GET users/123
# Routing Key: "users"
user = RemoteUser.find(123)
puts user.email 

# --- CREATE ---
# Envia: POST users
# Routing Key: "users"
# Body: { "email": "test@test.com", "role": "admin" }
user = RemoteUser.create(email: "test@test.com", role: "admin")

# --- UPDATE ---
# Envia: PUT users/123
# Routing Key: "users"
user.update(email: "edit@test.com") 
# Dirty Tracking: Solo se envían los campos modificados.

# --- DESTROY ---
# Envia: DELETE users/123
# Routing Key: "users"
user.destroy
```

### Estrategias de Routing

Tienes 3 formas de controlar la `routing_key` hacia donde se envían los mensajes:

| Nivel | Método | Descripción | Ejemplo Config |
| :--- | :--- | :--- | :--- |
| **1. Dinámico** | `resource_name` | (Por defecto) Usa el nombre del recurso. | `self.resource_name = 'users'` -> Key `users` |
| **2. Estático** | `routing_key` | Fuerza TODO a una sola cola. | `self.routing_key = 'cola_manager'` |
| **3. Temporal** | `.with(...)` | Override solo para esa petición. | `User.with(routing_key: 'urgent').create` |

---

## 🔌 Modo Publisher (Cliente Manual)

Si no necesitas mapear un recurso o quieres enviar mensajes crudos, utiliza `BugBunny::Client`. Soporta semántica REST pasando el argumento `method:`.

### 1. Instanciar el Cliente

```ruby
client = BugBunny::Client.new(pool: BUG_BUNNY_POOL) do |conn|
  # Puedes inyectar middlewares aquí
  conn.use BugBunny::Middleware::JsonResponse
end
```

### 2. Request (RPC Síncrono)

Envía el mensaje, **bloquea el hilo** y espera la respuesta JSON. Ideal para obtener datos.

```ruby
# GET (Leer)
response = client.request('users/123', method: :get)
puts response['body']

# POST (Crear / Ejecutar)
response = client.request('math/calc', method: :post, body: { a: 10, b: 20 })

# PUT (Actualizar)
client.request('users/123', method: :put, body: { active: true })

# DELETE (Borrar)
client.request('users/123', method: :delete)
```

### 3. Publish (Asíncrono / Fire-and-Forget)

Envía el mensaje y retorna inmediatamente. No espera respuesta. Por defecto usa `method: :post` si no se especifica.

```ruby
# Enviar log o evento
client.publish('logs/error', method: :post, body: { msg: 'Disk full' })
```

### 4. Configuración Avanzada (Bloques)

Puedes usar un bloque para configurar opciones de bajo nivel de AMQP (prioridad, expiración, headers, app_id).

```ruby
client.publish('jobs/process') do |req|
  req.method = :post
  req.body = { image_id: 99 }
  
  # Metadatos AMQP
  req.priority = 9         # Alta prioridad (0-9)
  req.expiration = '5000'  # TTL 5 segundos (ms)
  req.app_id = 'web-frontend'
  req.headers['X-Trace-Id'] = 'abc-123'
end
```

### 5. Referencia de Opciones

Estas opciones pueden pasarse como argumentos (`client.request(key: val)`) o dentro del bloque (`req.key = val`).

| Opción / Atributo | Tipo | Descripción | Default |
| :--- | :--- | :--- | :--- |
| `body` | `Hash/String` | El contenido del mensaje. | `nil` |
| `method` | `Symbol` | Verbo HTTP (`:get`, `:post`, `:put`, `:delete`). | `:get` (en request) |
| `exchange` | `String` | Nombre del Exchange destino. | `''` (Default Ex) |
| `routing_key` | `String` | Clave de ruteo. Si falta, usa el `path`. | `path` |
| `headers` | `Hash` | Headers personalizados. | `{}` |
| `timeout` | `Integer` | (Solo RPC) Segundos máx de espera. | Config global |
| `app_id` | `String` | ID de la aplicación origen. | `nil` |
| `priority` | `Integer` | Prioridad del mensaje (0-9). | `0` |
| `expiration` | `String` | TTL del mensaje en ms. | `nil` |

---

## 📡 Modo Servidor (El Worker)

BugBunny incluye un **Router Inteligente** que funciona igual que el `config/routes.rb` de Rails. Infiere la acción basándose en el **Verbo HTTP** y la estructura de la **URL**.

### 1. Definir Controladores

Crea tus controladores en `app/rabbit/controllers/`. Heredan de `BugBunny::Controller`.

```ruby
# app/rabbit/controllers/users_controller.rb
class UsersController < BugBunny::Controller

  # GET users
  def index
    users = User.where(active: params[:active])
    render status: 200, json: users
  end

  # GET users/123
  def show
    user = User.find(params[:id])
    render status: 200, json: user
  end

  # POST users
  def create
    user = User.new(params)
    if user.save
      render status: 201, json: user
    else
      # Estos errores se propagan como BugBunny::UnprocessableEntity
      render status: 422, json: { errors: user.errors }
    end
  end
  
  # PUT users/123
  def update
    # ...
  end

  # DELETE users/123
  def destroy
    # ...
  end
end
```

### 2. Tabla de Ruteo (Convención)

El Router despacha automáticamente según esta tabla:

| Header `x-http-method` | Header `type` (URL) | Controlador | Acción |
| :--- | :--- | :--- | :--- |
| `GET` | `users` | `UsersController` | `index` |
| `GET` | `users/12` | `UsersController` | `show` |
| `POST` | `users` | `UsersController` | `create` |
| `PUT` | `users/12` | `UsersController` | `update` |
| `DELETE` | `users/12` | `UsersController` | `destroy` |
| `POST` | `users/12/promote` | `UsersController` | `promote` (Custom) |

### 3. Ejecutar el Worker

```bash
bundle exec rake bug_bunny:work
```

---

## 🏗 Arquitectura REST-over-AMQP

BugBunny desacopla el transporte de la lógica usando headers AMQP estándar.

| Concepto | REST (HTTP) | BugBunny (AMQP) |
| :--- | :--- | :--- |
| **Recurso** | `POST /users` | Header `type`: `users` + Header `x-http-method`: `POST` |
| **Parametros** | Query String / Body | Header `type` (Query) + Body (Payload) |
| **Destino** | DNS / IP | Routing Key (ej: `users`) |
| **Status** | HTTP Code (200, 404) | JSON Response `status` |

---

## 🛠 Middlewares

BugBunny usa una pila de middlewares para procesar peticiones y respuestas, permitiendo logging, manejo de errores y transformación de datos.

```ruby
# Configuración global en el Resource
BugBunny::Resource.client_middleware do |conn|
  # 1. Lanza excepciones Ruby para errores 4xx/5xx
  conn.use BugBunny::Middleware::RaiseError

  # 2. Parsea JSON a HashWithIndifferentAccess
  conn.use BugBunny::Middleware::JsonResponse
end
```

### Excepciones Soportadas

* `BugBunny::BadRequest` (400)
* `BugBunny::NotFound` (404)
* `BugBunny::RequestTimeout` (408)
* `BugBunny::UnprocessableEntity` (422) - Incluye errores de validación.
* `BugBunny::InternalServerError` (500)

---

## 📄 Licencia

Código abierto bajo [MIT License](https://opensource.org/licenses/MIT).
