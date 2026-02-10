# 🐰 BugBunny

**BugBunny** es un framework RPC para Ruby on Rails sobre **RabbitMQ**.

Su filosofía es **"Active Record over AMQP"**. Transforma patrones de mensajería en una arquitectura **RESTful simulada**. Los mensajes viajan con un verbo HTTP (`POST`, `GET`) y una URL (`users/123`), y un Router inteligente los despacha al controlador y acción correspondiente siguiendo las convenciones de Rails.

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

## 🚀 Modo Resource (ORM / Active Record)

Define modelos que actúan como proxis de recursos remotos. BugBunny separa la **Lógica de Transporte** (RabbitMQ) de la **Lógica de Aplicación** (Controladores).

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

BugBunny traduce las llamadas de Ruby a peticiones HTTP simuladas sobre AMQP.

```ruby
# --- READ COLLECTION (Index) ---
# Envia: GET users?active=true
users = RemoteUser.where(active: true)

# --- READ MEMBER (Show) ---
# Envia: GET users/123
user = RemoteUser.find(123)
puts user.email 

# --- CREATE ---
# Envia: POST users
# Body: { "email": "test@test.com", "role": "admin" }
user = RemoteUser.create(email: "test@test.com", role: "admin")

# --- UPDATE ---
# Envia: PUT users/123
# Body: { "email": "edit@test.com" }
user.update(email: "edit@test.com") 
# Dirty Tracking: Solo se envían los campos modificados.

# --- DESTROY ---
# Envia: DELETE users/123
user.destroy
```

---

## 🔌 Modo Publisher (Cliente Manual)

Si no necesitas mapear un recurso o quieres enviar mensajes crudos, utiliza `BugBunny::Client`. Ahora soporta semántica REST.

### 1. Instanciar el Cliente

```ruby
client = BugBunny::Client.new(pool: BUG_BUNNY_POOL) do |conn|
  # Puedes inyectar middlewares aquí
  conn.use BugBunny::Middleware::JsonResponse
end
```

### 2. Métodos RESTful (Síncronos RPC)

Estos métodos envían el mensaje, bloquean el hilo y esperan la respuesta JSON.

```ruby
# GET
response = client.get('users/123')

# POST
response = client.post('users', body: { name: 'Gaby' })

# PUT
response = client.put('users/123', body: { active: true })

# DELETE
client.delete('users/123')
```

### 3. Publicación Asíncrona (Fire-and-Forget)

Usa `publish` para enviar sin esperar respuesta. Por defecto usa POST, pero puedes especificar el método.

```ruby
# Envía un evento asíncrono
client.publish('logs', method: :post, body: { level: 'error' })
```

### 4. Configuración Avanzada (Bloques)

Puedes usar un bloque para configurar opciones de bajo nivel de AMQP (prioridad, expiración, headers).

```ruby
client.post('jobs/process') do |req|
  req.body = { image_id: 99 }
  req.priority = 9         # Alta prioridad
  req.expiration = '5000'  # TTL 5 segundos
  req.app_id = 'web-frontend'
end
```

### 5. Referencia de Opciones

Estas opciones pueden pasarse como argumentos (`client.post(..., key: val)`) o dentro del bloque (`req.key = val`).

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

Crea tus controladores en `app/rabbit/controllers/`.

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

| Verbo | URL Pattern | Controlador | Acción |
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
| **Destino** | DNS / IP | Routing Key (`users`) |
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
