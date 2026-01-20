# 🐰 BugBunny

**BugBunny** es un framework de comunicación para Ruby on Rails sobre **RabbitMQ**.

Su objetivo es abstraer la complejidad de AMQP (Exchanges, Colas, Canales) y ofrecer una interfaz familiar para desarrolladores Rails. Soporta dos modos de operación principales:
1.  **Modo Resource:** Estilo `ActiveRecord` para mapear recursos remotos.
2.  **Modo Publisher:** Estilo Servicios/Cliente para enviar mensajes libres (Fire-and-forget o RPC).

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

Corre el instalador para generar la configuración y directorios:

```bash
rails g bug_bunny:install
```

Esto creará:
* `config/initializers/bug_bunny.rb`
* `app/rabbit/controllers/`

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
  config.rpc_timeout = 10     # Segundos a esperar respuesta síncrona
  config.network_recovery_interval = 5
end

# Definimos el Pool Global (Vital para Puma/Sidekiq)
BUG_BUNNY_POOL = ConnectionPool.new(size: ENV.fetch('RAILS_MAX_THREADS', 5).to_i, timeout: 5) do
  BugBunny.create_connection
end

# Inyectamos el pool por defecto a los recursos (si usas el modo Resource)
BugBunny::Resource.connection_pool = BUG_BUNNY_POOL
```

---

## 🚀 Opción A: Modo Resource (Active Resource)

Ideal para CRUDs remotos. Define modelos que representan recursos en otros microservicios.

### 1. Definir el Modelo

```ruby
# app/models/remote_user.rb
class RemoteUser < BugBunny::Resource
  # Configuración de Ruteo
  self.exchange = 'users_exchange'
  self.exchange_type = 'topic'
  self.routing_key_prefix = 'users' 
  # Esto generará rutas automáticas: 'users.show', 'users.create', etc.

  # Atributos (ActiveModel)
  attribute :id, :integer
  attribute :name, :string
  attribute :email, :string

  # Validaciones Locales
  validates :email, presence: true
end
```

### 2. Consumir el Servicio (CRUD)

La API es idéntica a ActiveRecord. Por debajo, esto envía mensajes AMQP y espera la respuesta (RPC).

```ruby
# --- FIND (RPC: 'users.show') ---
user = RemoteUser.find(123)
puts user.name # => "Gabriel"

# --- CREATE (RPC: 'users.create') ---
user = RemoteUser.new(name: "Nuevo", email: "test@test.com")
if user.save
  puts "Usuario creado con ID: #{user.id}"
else
  puts "Errores remotos: #{user.errors.full_messages}"
end
```

### 3. Configuración Dinámica (`.with`)

```ruby
# Usar otro exchange o pool solo para esta llamada
RemoteUser.with(exchange: 'legacy_exchange').find(99)
```

---

## 🔌 Opción B: Modo Publisher (Sin Active Resource)

Si prefieres un control total o no estás mapeando un recurso REST, puedes usar `BugBunny::Client` directamente. Se recomienda encapsularlo en clases "Publisher".

### 1. Crear un Publisher

```ruby
# app/publishers/notification_publisher.rb
class NotificationPublisher
  # Instanciamos el cliente inyectándole el Pool
  def self.client
    @client ||= BugBunny::Client.new(pool: BUG_BUNNY_POOL)
  end

  # Ejemplo 1: Fire-and-Forget (Asíncrono)
  # Envía el mensaje y retorna inmediatamente. Ideal para eventos.
  def self.send_alert(msg)
    client.publish('alerts/create', 
      body: { message: msg, timestamp: Time.now },
      exchange: 'notifications_exchange',
      exchange_type: 'topic',
      routing_key: 'alerts.critical'
    )
  end

  # Ejemplo 2: RPC (Síncrono)
  # Envía el mensaje y espera la respuesta del consumidor.
  def self.check_status(service_id)
    response = client.request('status/check',
      body: { service: service_id },
      exchange: 'system_exchange',
      routing_key: 'system.status',
      timeout: 5 # Timeout específico para esta llamada
    )
    
    # Retorna el body parseado (Hash)
    response['body'] 
  end
end
```

### 2. Usar el Publisher

```ruby
# En un controller o Job
NotificationPublisher.send_alert("Servidor caído")

status = NotificationPublisher.check_status("database")
puts status['uptime']
```

---

## 📡 Uso: El Servidor (Workers)

BugBunny incluye un servidor capaz de procesar mensajes entrantes (tanto de Resources como de Publishers) y enrutarlos a controladores.

### 1. Definir Controladores

Crea tus controladores en `app/rabbit/controllers/`. Deben heredar de `BugBunny::Controller`.

```ruby
# app/rabbit/controllers/users_controller.rb
module Rabbit
  module Controllers
    class Users < BugBunny::Controller
      
      # Acción para routing_key: 'users.show'
      def show
        # Tienes acceso a headers y params
        user = User.find_by(id: params[:id])

        if user
          render status: 200, json: user.as_json
        else
          render status: 404, json: { error: 'No encontrado' }
        end
      end

      # Acción para routing_key: 'users.create'
      def create
        user = User.new(params)
        
        if user.save
          render status: 201, json: user.as_json
        else
          # Estos errores se propagarán al cliente remoto
          render status: 422, json: { errors: user.errors.full_messages }
        end
      end
    end
  end
end
```

### 2. Ejecutar el Worker

BugBunny usa un Rake task inteligente que detecta tus controladores y se conecta a RabbitMQ.

```bash
# En tu terminal o Dockerfile
bundle exec rake bug_bunny:work
```

Esto iniciará un proceso bloqueante que escucha en la cola configurada (por defecto `[app_name]_rpc_queue`).

**En Kubernetes:**
Simplemente escala el número de réplicas de este worker. BugBunny usa el patrón "Work Queue", por lo que RabbitMQ balanceará la carga automáticamente entre todos los pods.

---

## 🛠 Avanzado: Middlewares

BugBunny soporta middlewares estilo Faraday en el cliente. Esto es útil para logging, tracing (OpenTelemetry), o manejo de errores global.

```ruby
# Instanciar cliente con Middleware
client = BugBunny::Client.new(pool: BUG_BUNNY_POOL) do |conn|
  conn.use BugBunny::Middleware::Logger, Rails.logger
  conn.use MyCustomMetricsMiddleware
end
```

---

## ⚠️ Manejo de Errores

BugBunny lanza excepciones específicas que puedes capturar:

| Excepción | Causa |
| :--- | :--- |
| `BugBunny::RequestTimeout` | El servidor no respondió a tiempo (RPC). |
| `BugBunny::UnprocessableEntity` | Error de validación (422) remoto. |
| `BugBunny::ClientError` | Errores 4xx genéricos. |
| `BugBunny::ServerError` | Errores 5xx (Excepción en el worker remoto). |
| `BugBunny::CommunicationError` | Fallo de conexión con RabbitMQ. |

---

## Teoria

## Resiliencia y Recuperación Automática
Estos parámetros son fundamentales para manejar fallos de red y garantizar que la aplicación se recupere sin intervención manual.

- *automatically_recover*: Indica al cliente Bunny que debe intentar automáticamente reestablecer la conexión y todos los recursos asociados (canales, colas, exchanges) si la conexión se pierde debido a un fallo de red o un reinicio del broker. Nota: Este parámetro puede entrar en conflicto con un bucle de retry manual).
- *network_recovery_interval*: El tiempo que Bunny esperará entre intentos consecutivos de reconexión de red.
- *heartbeat*: El intervalo de tiempo (en segundos) en el que el cliente y el servidor deben enviarse un pequeño paquete ("latido"). Si no se recibe un heartbeat durante dos intervalos consecutivos, se asume que la conexión ha muerto (generalmente por un fallo de red o un proceso colgado), lo que dispara el mecanismo de recuperación.

## Tiempos de Espera (Timeouts)
 Estos parámetros previenen que la aplicación se bloquee indefinidamente esperando una respuesta del servidor.

- *connection_timeout*: Tiempo máximo (en segundos) que Bunny esperará para establecer la conexión TCP inicial con el servidor RabbitMQ.
- *read_timeout*: Tiempo máximo (en segundos) que la conexión esperará para leer datos del socket. Si el servidor se queda en silencio por más de 30 segundos, el socket se cerrará.
- *write_timeout*: Tiempo máximo (en segundos) que la conexión esperará para escribir datos en el socket. Útil para manejar escenarios donde la red es lenta o está congestionada.
- *continuation_timeout*: Es un timeout interno de protocolo AMQP (dado en milisegundos). Define cuánto tiempo esperará el cliente para que el servidor responda a una operación que requiere múltiples frames o pasos (como una transacción o una confirmación compleja). En este caso, son 15 segundos.

## 📄 Licencia

La gema está disponible como código abierto bajo los términos de la [MIT License](https://opensource.org/licenses/MIT).
