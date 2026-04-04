# Controllers

## Estructura Base

```ruby
class UsersController < BugBunny::Controller
  before_action :authenticate, only: [:create, :update, :destroy]
  around_action :with_tracing
  after_action :log_response, only: [:index, :show]
  rescue_from BugBunny::NotFound, with: :render_not_found

  def index
    users = UserService.list(params[:filter])
    render status: :ok, json: { users: users }
  end

  def show
    user = UserService.find(params[:id])
    render status: :ok, json: user
  end

  private

  def authenticate
    render status: :forbidden, json: { error: 'Unauthorized' } unless valid_token?
  end

  def with_tracing
    Tracer.start
    yield
  ensure
    Tracer.finish
  end

  def log_response
    logger.info("Response: #{rendered_response[:status]}")
  end

  def render_not_found(exception)
    render status: :not_found, json: { error: exception.message }
  end
end
```

## Callbacks — Orden de Ejecución

1. `around_action` blocks (capa externa, envuelve todo con `yield`)
2. `before_action` callbacks (se detiene si se llama `render`)
3. Acción del controlador
4. `after_action` callbacks (NO se ejecuta si before_action haltó o si hubo excepción)

## Filtros: only / except

```ruby
before_action :authenticate, only: [:create, :update]
after_action :audit, except: [:index]
```

## rescue_from

Captura excepciones con handler method o bloque:

```ruby
rescue_from BugBunny::UnprocessableEntity, with: :handle_validation
rescue_from StandardError do |e|
  render status: :internal_server_error, json: { error: e.message }
end
```

## Atributos Disponibles en el Controller

```ruby
@headers             # Hash — metadata del mensaje AMQP (method, routing_key, id, etc.)
@params              # HashWithIndifferentAccess — body JSON + query params unificados
@raw_string          # String — body crudo si no es JSON
@response_headers    # Hash — headers para el reply RPC
@rendered_response   # Hash o nil — respuesta renderizada
```

## Render

```ruby
render(status: :ok, json: { users: [...] })
render(status: 201, json: @user)
render(status: :unprocessable_entity, json: { errors: @resource.errors }, headers: { 'X-Custom' => 'val' })
```

Si no se llama `render`, el response default es `{ status: 204, body: nil }`.

## Log Tags

```ruby
# Global
BugBunny.configuration.log_tags = [:uuid, :user_id, ->(c) { c.current_user }]

# Por controller
class UsersController < BugBunny::Controller
  self.log_tags = [:uuid]
end
```

Tipos soportados:
- **Symbol:** Llama al método del controller (ej: `:uuid` → `self.uuid`)
- **Proc:** Ejecuta con el controller como argumento
- **String:** Valor literal
