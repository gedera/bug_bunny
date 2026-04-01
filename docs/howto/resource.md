# Resource ORM

`BugBunny::Resource` provides an ActiveRecord-like interface for remote services. Each Resource class represents a resource type in another microservice, reachable via RabbitMQ.

## Defining a Resource

```ruby
class RemoteNode < BugBunny::Resource
  # AMQP infrastructure
  self.exchange      = 'inventory_exchange'
  self.exchange_type = 'direct'           # default
  self.resource_name = 'nodes'            # used as the path prefix and routing key

  # Typed attributes (ActiveModel::Attributes)
  attribute :name,      :string
  attribute :status,    :string
  attribute :cpu_cores, :integer
  attribute :active,    :boolean

  # Validations (ActiveModel::Validations)
  validates :name,   presence: true
  validates :status, inclusion: { in: %w[pending active draining decommissioned] }
end
```

## Connection Pool

All Resource classes in a service typically share one pool:

```ruby
# config/initializers/bug_bunny.rb
BUG_BUNNY_POOL = ConnectionPool.new(size: 5, timeout: 5) do
  BugBunny.create_connection
end

BugBunny::Resource.connection_pool = BUG_BUNNY_POOL
```

Individual classes can override:

```ruby
RemoteNode.connection_pool = OTHER_POOL
```

---

## CRUD

```ruby
# Find by ID — returns nil on 404
node = RemoteNode.find('node-123')

# List all
nodes = RemoteNode.all

# Filter — query params forwarded to the consumer
nodes = RemoteNode.where(status: 'active')
nodes = RemoteNode.where(q: { cpu_cores: 4 }, page: 2)

# Create
node = RemoteNode.create(name: 'web-01', status: 'pending')
node.persisted?  # => true if save succeeded

# Update
node = RemoteNode.find('node-123')
node.status = 'active'
node.save        # PUT nodes/node-123

# Update (shorthand)
node.update(status: 'active', name: 'web-01')

# Destroy
node.destroy     # DELETE nodes/node-123
```

---

## Typed vs Dynamic Attributes

### Typed attributes

Declared with `attribute :name, :type`. Benefit from ActiveModel coercions, dirty tracking, and validations:

```ruby
attribute :cpu_cores, :integer
attribute :enabled,   :boolean
attribute :score,     :decimal
```

### Dynamic attributes

Any key received from the remote service that is not declared as a typed attribute is stored dynamically and accessible via `method_missing`:

```ruby
node = RemoteNode.find('node-123')
node.docker_id      # => "abc123xyz" (not declared, but present in the response)
node.docker_id = 'new-id'
node.changed?       # => true
node.changed        # => ['docker_id']
```

Dynamic attributes participate in `changed?`, `changed`, and `changes_to_send` — so they are serialized correctly on `save`.

---

## Change Tracking

BugBunny::Resource merges ActiveModel::Dirty (for typed attributes) with its own tracking for dynamic attributes.

```ruby
node = RemoteNode.find('node-123')  # changes cleared after find
node.changed?                       # => false

node.status = 'draining'
node.changed?                       # => true
node.changed                        # => ['status']

node.save                           # sends only changed attrs
node.changed?                       # => false (cleared after save)
```

`save` on a new record (not persisted) sends all attributes.

---

## Validations

```ruby
node = RemoteNode.new(name: '', status: 'invalid')
node.valid?          # => false
node.errors.full_messages
# => ["Name can't be blank", "Status is not included in the list"]

node.save            # => false (does not send the request)
```

Remote validation errors (422 responses) are loaded back into the object:

```ruby
node = RemoteNode.create(name: 'duplicate-name')
node.persisted?                    # => false
node.errors[:name]                 # => ["has already been taken"]
```

---

## Callbacks

```ruby
class RemoteNode < BugBunny::Resource
  before_save  :normalize_name
  after_create :notify_provisioner
  around_save  :with_timing

  private

  def normalize_name
    self.name = name.to_s.downcase.strip
  end
end
```

Available callbacks: `before_save`, `after_save`, `before_create`, `after_create`, `before_update`, `after_update`, `before_destroy`, `after_destroy`.

---

## Dynamic Exchange Configuration with `.with`

Override AMQP settings for a single operation without changing the class defaults:

```ruby
# Different exchange for a single call
RemoteNode.with(exchange: 'us-east-inventory').where(status: 'active')

# Different routing key
RemoteNode.with(routing_key: 'nodes.priority').find('node-123')

# Chain is single-use — call .with again for the next operation
RemoteNode.with(exchange: 'staging').create(name: 'test-node')
```

`.with` sets thread-local values that are cleaned up after the single operation completes, even if an exception is raised.

---

## Payload Wrapping

By default, `save` wraps the payload under a root key derived from the model name:

```ruby
# RemoteNode → root key: 'node'
node.save
# Sends: { "node" => { "name" => "web-01", "status" => "active" } }
```

The consumer can then use `params.require(:node)` in the controller. Override the root key:

```ruby
self.param_key = 'server'
```
