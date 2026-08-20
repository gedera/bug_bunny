# Resources

## Definición

```ruby
class Order < BugBunny::Resource
  # Infraestructura AMQP
  @connection_pool = MY_POOL
  @exchange = 'orders_ex'
  @exchange_type = 'topic'
  @resource_name = 'orders'        # path en la URL
  @routing_key = 'orders.#'
  @param_key = 'order'             # wrapper key en payloads
  @exchange_options = { durable: true }
  @queue_options = { auto_delete: false }

  # Atributos tipados (ActiveModel::Attributes)
  attribute :id, :integer
  attribute :status, :string
  attribute :total, :decimal
  attribute :active, :boolean

  # Validaciones (ActiveModel::Validations)
  validates :status, presence: true

  # Callbacks
  before_save :normalize_status
  after_create :notify_warehouse
  around_destroy :audit_deletion

  # Middleware client-side
  client_middleware do |stack|
    stack.use BugBunny::Middleware::RaiseError
    stack.use BugBunny::Middleware::JsonResponse
  end
end
```

## Operaciones CRUD

### Class Methods

```ruby
Order.find(42)                           # GET orders/42 → Order
Order.where(status: 'active')            # GET orders?status=active → [Order, ...]
Order.all                                # GET orders → [Order, ...]
Order.create(status: 'pending', total: 100) # POST orders → Order
```

### Instance Methods

```ruby
order = Order.new(status: 'pending')
order.save                               # POST orders (nuevo) o PUT orders/42 (existente)
order.update(status: 'shipped')          # assign + save
order.destroy                            # DELETE orders/42
order.persisted?                         # true si fue guardado
order.changed?                           # true si tiene cambios sin guardar
order.errors                             # ActiveModel::Errors
```

### Save: Create vs Update

- **Nuevo** (`persisted? == false`): Envía POST con todos los atributos.
- **Existente** (`persisted? == true`): Envía PUT solo con atributos cambiados (`changes_to_send`).
- Captura `BugBunny::UnprocessableEntity` (422) y carga `resource.errors`. Retorna `false`.

### Params top-level hermanos: `extra_top_level_params`

Por default `save` envía el body `{ param_key => attrs }`. Una subclase puede sobrescribir `extra_top_level_params` (default `{}`) para mergear datos **top-level hermanos** del recurso —fuera del wrapper `param_key`— sin que sean atributos del recurso ni se persistan en el modelo. Caso de uso: un dato de transporte (p. ej. una credencial) que el servidor lee como `params[:x]`.

```ruby
class Service < BugBunny::Resource
  self.param_key = 'service'
  attr_accessor :registry_auth   # dato transiente, NO atributo del recurso

  def extra_top_level_params
    registry_auth ? { registry_auth: registry_auth } : {}
  end
end
# save envía: { 'service' => { ...attrs }, registry_auth: '...' }
```

No debe usar `param_key` como clave (colisionaría con el wrapper del recurso).

## Contexto Dinámico (.with)

### Forma de bloque (recomendada)

```ruby
Order.with(exchange: 'priority_ex', routing_key: 'priority.orders') do
  Order.all                    # Usa config temporal
  Order.find(1)                # También usa config temporal
end
# Config restaurada automáticamente
```

### Forma de cadena (single use)

```ruby
order = Order.with(pool: special_pool).find(42)
# Siguiente llamada requiere nuevo .with()
```

**Antipatrón:** No guardar el proxy en variable para múltiples llamadas → lanza error.

## Change Tracking

Combina `ActiveModel::Dirty` con atributos dinámicos:

```ruby
order = Order.find(42)
order.name = 'New Name'              # Atributo definido
order.custom_field = 'value'         # Atributo dinámico
order.changed                        # → ['name', 'custom_field']
order.changes_to_send                # → { 'name' => 'New Name', 'custom_field' => 'value' }
```

### Colisión entre un atributo dinámico y un método homónimo

`changes_to_send` lee cada valor con `public_send(key)`, así que un **método de
instancia definido en el modelo** con el mismo nombre que un atributo dinámico
**gana** sobre el valor seteado. Es deliberado: hay modelos cuyo reader devuelve
el valor ya normalizado y es ese el que tiene que viajar.

La excepción es el caso mudo: **un atributo que el caller seteó explícitamente
nunca se envía como `nil`.** Si el método homónimo resuelve a `nil` —el patrón
del reader de conveniencia sobre el shape que devuelve el servidor, que sobre un
objeto recién construido no encuentra el campo— gana el valor del atributo.

```ruby
class Container < BugBunny::Resource
  def name                      # reader del *inspect* del servidor
    self.Name&.delete_prefix('/')
  end
end

c = Container.new('name' => 'helper_1')
c.name                          # → nil (todavía no hay `Name`: no vino del servidor)
c.changes_to_send               # → { 'name' => 'helper_1' }   ← el atributo, no el nil
```

Sin esa regla la key viajaba presente y en `nil`: sin excepción, y un `compact`
del otro lado la borraba sin dejar rastro (#62).

## Callbacks Disponibles

Definidos con `define_model_callbacks`:
- `:save` — before/after/around save (create o update)
- `:create` — before/after/around create (recurso nuevo)
- `:update` — before/after/around update (recurso existente)
- `:destroy` — before/after/around destroy

## Coerción de Tipos

Los atributos tipados usan `ActiveModel::Attributes`:
- `'25.50'` → `BigDecimal` (con `:decimal`)
- `'1'` / `'true'` → `true` (con `:boolean`)
- `'2026-04-01T...'` → `Time` (con `:time`)

Los atributos dinámicos (no declarados) se almacenan sin coerción.
