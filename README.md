# 🐰 BugBunny

**BugBunny** es un framework RPC para Ruby on Rails sobre **RabbitMQ**.

Su filosofía es **"Active Record over AMQP"**. Abstrae la complejidad de colas y exchanges transformando patrones de mensajería en una arquitectura **RESTful simulada**, donde los mensajes contienen "URLs" (Header `type`) y "Query Params" que son enrutados automáticamente a controladores.

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

### Definición Básica

```ruby
class RemoteUser < BugBunny::Resource
  # 1. Configuración de Transporte
  self.exchange = 'app.topic'
  self.exchange_type = 'topic'
  
  # 2. Configuración Lógica
  # Define el nombre base. Se usa para:
  # - Routing Key automática: 'users.create', 'users.show.12'
  # - Header Type (URL): 'users/create'
  self.resource_name = 'users'

  # Nota: BugBunny es Schema-less. No necesitas definir atributos.
  # Soporta acceso dinámico: user.Name, user.email, etc.
end
```

### Estrategias de Routing (Routing Key)

Tienes 3 formas de controlar hacia dónde se envían los mensajes:

| Nivel | Método | Descripción | Ejemplo Config |
| :--- | :--- | :--- | :--- |
| **1. Dinámico** | `resource_name` | (Por defecto) Genera keys basadas en acción. | `self.resource_name = 'users'` -> `users.create` |
| **2. Estático** | `routing_key` | Fuerza TODO a una sola cola. | `self.routing_key = 'cola_manager'` |
| **3. Temporal** | `.with(...)` | Override solo para esa petición. | `User.with(routing_key: 'urgent').create` |

### Consumiendo el Servicio (CRUD)

```ruby
# --- READ (Colección con Filtros) ---
# Header Type: "users/index?active=true"
# Routing Key: "users.index"
users = RemoteUser.where(active: true)

# --- READ (Singular) ---
# Header Type: "users/show/123"
# Routing Key: "users.show.123"
user = RemoteUser.find(123)
puts user.email 

# --- CREATE ---
# Header Type: "users/create"
# Routing Key: "users.create"
user = RemoteUser.create(email: "test@test.com", role: "admin")

# --- UPDATE ---
# Header Type: "users/update/123"
# Routing Key: "users.update.123"
user.update(email: "edit@test.com") 
# Dirty Tracking: Solo se envían los campos modificados.

# --- DESTROY ---
# Header Type: "users/destroy/123"
# Routing Key: "users.destroy.123"
user.destroy
```

---

## 🔌 Modo Publisher (Cliente Manual)

Si no necesitas mapear un recurso o quieres enviar mensajes crudos ("Fire-and-Forget"), utiliza `BugBunny::Client`.

### 1. Instanciar el Cliente

```ruby
client = BugBunny::Client.new(pool: BUG_BUNNY_POOL) do |conn|
  # Puedes inyectar middlewares aquí
  conn.use BugBunny::Middleware::JsonResponse
end
```

### 2. Métodos de Envío

El cliente expone dos métodos principales: `publish` (Asíncrono) y `request` (Síncrono/RPC). Ambos aceptan **argumentos nombrados** y/o un **bloque de configuración**.

#### A. Publicar (Fire-and-Forget)
Envía el mensaje y retorna inmediatamente. No espera respuesta.

```ruby
# Opción 1: Argumentos Inline (Rápido y simple)
client.publish('logs/warn', 
  exchange: 'logs.topic',
  routing_key: 'app.warn',
  body: { msg: 'Disco lleno' }
)

# Opción 2: Bloque (Para control granular de AMQP)
client.publish('logs/warn') do |req|
  req.exchange = 'logs.topic'
  req.routing_key = 'app.warn'
  req.body = { msg: 'Disco lleno' }
  
  # Metadatos avanzados AMQP
  req.expiration = '1000' # TTL en ms (muere si no se consume en 1s)
  req.priority = 9        # Prioridad alta
  req.app_id = 'backend-worker-1'
end
```

#### B. Request (RPC Síncrono)
Envía el mensaje y **bloquea el hilo** esperando la respuesta del consumidor. Lanza `BugBunny::RequestTimeout` si expira el tiempo.

```ruby
begin
  response = client.request('math/calculate', 
    exchange: 'rpc.direct', 
    routing_key: 'calculator',
    body: { a: 10, b: 20 },
    timeout: 5 # Esperar máx 5 segundos
  )
  
  puts response['body'] # => { "result": 30 }

rescue BugBunny::RequestTimeout
  puts "El servidor tardó demasiado."
end
```

### 3. Referencia de Opciones

Estas opciones pueden pasarse como argumentos (`client.publish(key: val)`) o dentro del bloque (`req.key = val`).

| Opción / Atributo | Tipo | Descripción | Default |
| :--- | :--- | :--- | :--- |
| `body` | `Hash/String` | El contenido del mensaje. | `nil` |
| `exchange` | `String` | Nombre del Exchange destino. | `''` (Default Ex) |
| `exchange_type` | `String` | Tipo: `direct`, `topic`, `fanout`, `headers`. | `'direct'` |
| `routing_key` | `String` | Clave de ruteo de RabbitMQ. | Valor de `url` |
| `headers` | `Hash` | Headers personalizados (metadatos de app). | `{}` |
| `timeout` | `Integer` | (Solo RPC) Segundos máx de espera. | Config global |
| `app_id` | `String` | ID de la aplicación origen. | `nil` |
| `content_type` | `String` | Tipo MIME del body. | `'application/json'` |
| `priority` | `Integer` | Prioridad del mensaje (0-9). | `0` |
| `expiration` | `String` | TTL del mensaje en milisegundos. | `nil` |
| `persistent` | `Boolean` | Si RabbitMQ debe guardar en disco. | `false` |

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
| **Destino Físico** | IP/Dominio | Routing Key (`users.create`) | `routing_key` / `resource_name` |
| **Payload** | Body (JSON) | Body (JSON) | N/A |
| **Status** | HTTP Code (200, 404) | JSON Response `status` | N/A |

---

## 🛠 Middlewares

BugBunny usa una pila de middlewares para procesar respuestas, similar a Faraday.

```ruby
# Configuración global en el Resource
BugBunny::Resource.client_middleware do |conn|
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
