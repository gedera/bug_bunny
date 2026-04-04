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
