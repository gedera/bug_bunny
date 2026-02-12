# 🐰 BugBunny

**BugBunny** es un framework RPC para Ruby on Rails sobre **RabbitMQ**.

Su filosofía es **"RESTful over AMQP"**. A diferencia de otros clientes de mensajería, BugBunny transforma patrones de colas en una arquitectura de recursos semántica. Los mensajes viajan con un **Verbo HTTP** (`GET`, `POST`, `PUT`, `DELETE`) y una **URL**, y son enrutados automáticamente a controladores Rails estándar.

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

---

## ⚙️ Configuración

Configura tus credenciales y opciones en `config/initializers/bug_bunny.rb`.

### Opciones Disponibles

```ruby
BugBunny.configure do |config|
  # --- Conexión ---
  config.host     = ENV.fetch('RABBITMQ_HOST', 'localhost')
  config.username = ENV.fetch('RABBITMQ_USER', 'guest')
  config.password = ENV.fetch('RABBITMQ_PASS', 'guest')
  config.vhost    = ENV.fetch('RABBITMQ_VHOST', '/')

  # --- Timeouts & Recuperación ---
  config.rpc_timeout = 10               # Segundos máx para esperar respuesta síncrona
  config.network_recovery_interval = 5  # Segundos antes de reintentar conexión

  # --- Logging (Nuevo en v3.0.1) ---
  # BugBunny Logger: Muestra tus requests (INFO recomendado)
  config.logger = Logger.new(STDOUT)
  config.logger.level = Logger::INFO

  # Driver Logger (Bunny): Silencia el ruido de bajo nivel (WARN recomendado)
  config.bunny_logger = Logger.new(STDOUT)
  config.bunny_logger.level = Logger::WARN
end
```

### Configuración del Pool (Crítico)

Para entornos concurrentes como **Puma** o **Sidekiq**, debes definir un `ConnectionPool` global.

```ruby
# config/initializers/bug_bunny.rb

BUG_BUNNY_POOL = ConnectionPool.new(size: ENV.fetch('RAILS_MAX_THREADS', 5).to_i, timeout: 5) do
  BugBunny.create_connection
end

# Inyecta el pool a los recursos para que lo usen automáticamente
BugBunny::Resource.connection_pool = BUG_BUNNY_POOL
```

---

## 🚀 Modo Resource (ORM / Active Record)

Define modelos que actúan como proxies de recursos remotos. BugBunny se encarga de serializar, enviar el verbo correcto y deserializar la respuesta.

### Definición del Modelo

```ruby
# app/models/remote_node.rb
class RemoteNode < BugBunny::Resource
  # 1. Configuración de Transporte
  self.exchange = 'cluster_manager'
  self.exchange_type = 'direct'
  
  # 2. Configuración Lógica
  # Define la URL base y la routing key por defecto.
  self.resource_name = 'nodes' 

  # Nota: Es "Schema-less". No defines atributos, se leen dinámicamente del JSON.
end
```

### CRUD RESTful (Ejemplos)

Las operaciones de Active Record se traducen automáticamente a verbos HTTP sobre AMQP.

#### 1. Leer (GET)
```ruby
# GET nodes
# Routing Key: 'nodes'
nodes = RemoteNode.all

# GET nodes?role=worker
workers = RemoteNode.where(role: 'worker')

# GET nodes/123
# Routing Key: 'nodes' (o lo que defina el modelo)
node = RemoteNode.find('123')

# Acceso a datos (Schema-less)
puts node.hostname            # Accessor dinámico (si existe en el JSON)
puts node.Description['IP']   # Acceso directo al Hash crudo
```

#### 2. Crear (POST)
```ruby
# POST nodes
# Body: { hostname: 'server-1', ip: '10.0.0.1' }
node = RemoteNode.create(hostname: 'server-1', ip: '10.0.0.1')
puts node.persisted? # => true
```

#### 3. Actualizar (PUT)
```ruby
# PUT nodes/123
node = RemoteNode.find('123')
node.update(ip: '10.0.0.2') # Solo envía los campos modificados
```

#### 4. Eliminar (DELETE)
```ruby
# DELETE nodes/123
node.destroy
```

### Contexto Dinámico (`.with`)

Puedes cambiar la configuración (Exchange, Routing Key) para una operación específica sin afectar al modelo global.

**Caso de Uso:** Guardar un objeto en una cola específica.

```ruby
# La instancia 'service' nace sabiendo que pertenece a la routing_key 'urgent'
service = RemoteService.with(routing_key: 'urgent').new(name: 'nginx')

# ... pasa el tiempo o cambia el scope ...

# Al guardar, BugBunny recuerda el contexto y envía a 'urgent'
service.save 
# Log: [POST] Target: 'services' | Routing Key: 'urgent'
```

---

## 🔌 Modo Publisher (Cliente Manual)

Si necesitas enviar mensajes crudos o invocar acciones que no encajan en un modelo CRUD, usa `BugBunny::Client`.

### Instanciación

```ruby
client = BugBunny::Client.new(pool: BUG_BUNNY_POOL) do |conn|
  conn.use BugBunny::Middleware::JsonResponse
end
```

### Métodos Principales

Ambos métodos aceptan el argumento `method:` (`:get`, `:post`, `:put`, `:delete`).

#### A. Request (Síncrono / RPC)
Envía el mensaje y **espera** la respuesta. Lanza `BugBunny::RequestTimeout` si tarda demasiado.

```ruby
# GET simple
response = client.request('nodes/123', method: :get)

# POST con body y headers custom
response = client.request('tasks/execute', 
  method: :post, 
  body: { script: 'backup.sh' },
  headers: { 'X-Auth' => 'secret' },
  timeout: 20 # Esperar hasta 20s
)

puts response['body'] # => { "status": "ok" }
```

#### B. Publish (Asíncrono / Fire-and-Forget)
Envía y retorna inmediatamente. No espera confirmación.

```ruby
# Enviar un evento
client.publish('logs/error', method: :post, body: { msg: 'Disk full' })
```

### Configuración Avanzada (Bloques)

Usa un bloque para acceso total a las opciones de AMQP (`expiration`, `priority`, `app_id`).

```ruby
client.publish('jobs/encode') do |req|
  req.method = :post
  req.body = { video_id: 99 }
  
  # Opciones AMQP 0.9.1
  req.priority = 9         # Alta prioridad
  req.expiration = '5000'  # TTL (ms)
  req.app_id = 'video-service'
  req.persistent = true    # Persistir en disco
end
```

---

## 📡 Modo Servidor (Worker & Router)

BugBunny incluye un **Router Inteligente** que despacha mensajes a controladores basándose en el Verbo y el Path, imitando a Rails.

### 1. Definir el Controlador

Crea tus controladores en `app/rabbit/controllers/`.

```ruby
# app/rabbit/controllers/nodes_controller.rb
class NodesController < BugBunny::Controller

  # GET nodes
  def index
    # params incluye query params y body mezclados
    nodes = Node.where(role: params[:role])
    render status: 200, json: nodes
  end

  # GET nodes/123
  def show
    # params[:id] se extrae automágicamente de la URL
    node = Node.find(params[:id])
    render status: 200, json: node
  end

  # POST nodes
  def create
    node = Node.new(params)
    if node.save
      render status: 201, json: node
    else
      render status: 422, json: { errors: node.errors }
    end
  end
end
```

### 2. Tabla de Ruteo (Convención)

El Router infiere la acción automáticamente:

| Verbo | URL Pattern | Controlador | Acción |
| :--- | :--- | :--- | :--- |
| `GET` | `nodes` | `NodesController` | `index` |
| `GET` | `nodes/12` | `NodesController` | `show` |
| `POST` | `nodes` | `NodesController` | `create` |
| `PUT` | `nodes/12` | `NodesController` | `update` |
| `DELETE` | `nodes/12` | `NodesController` | `destroy` |
| `POST` | `nodes/12/restart` | `NodesController` | `restart` (Custom) |

### 3. Ejecutar el Worker

```bash
bundle exec rake bug_bunny:work
```

---

## 🏗 Arquitectura REST-over-AMQP

BugBunny desacopla el transporte de la lógica usando headers estándar.

1.  **Transporte:** El mensaje viaja por RabbitMQ usando `exchange` y `routing_key`.
2.  **Semántica:** El mensaje lleva headers `type` (URL) y `x-http-method` (Verbo).
3.  **Ruteo:** El consumidor lee la semántica y ejecuta el controlador correspondiente.

### Logs Estructurados

BugBunny 3.0.1 introduce logs detallados para facilitar el debugging:

```text
[BugBunny] [POST] Target: 'services' | Exchange: 'cluster' (Type: direct) | Routing Key: 'node-1'
```

---

## 📄 Licencia

Código abierto bajo [MIT License](https://opensource.org/licenses/MIT).
