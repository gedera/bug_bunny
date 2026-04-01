# Controllers

Controllers receive routed messages and produce responses. They follow the same lifecycle as ActionController in Rails.

## Defining a Controller

```ruby
module BugBunny
  module Controllers
    class NodesController < BugBunny::Controller
      def index
        nodes = Node.all
        render status: :ok, json: nodes.map(&:as_json)
      end

      def show
        node = Node.find(params[:id])
        render status: :ok, json: node.as_json
      end

      def create
        node = Node.new(node_params)
        if node.save
          render status: :created, json: node.as_json
        else
          render status: :unprocessable_entity, json: { errors: node.errors }
        end
      end
    end
  end
end
```

The controller namespace defaults to `BugBunny::Controllers`. Override it globally with `config.controller_namespace`, or per route group with `namespace` blocks in the DSL.

---

## params

`params` merges path parameters, query string parameters, and body parameters into a single `HashWithIndifferentAccess`:

```ruby
# Message for PUT nodes/42?verbose=true with body { "node": { "status": "active" } }
params[:id]            # => "42"        (from path)
params[:verbose]       # => "true"      (from query string)
params[:node][:status] # => "active"    (from JSON body)
```

Use strong-parameters style to extract what you need:

```ruby
def node_params
  params.require(:node).permit(:name, :status)
end
```

---

## before_action

Runs before the action. Rendering inside a `before_action` halts the chain — the action and `after_action` callbacks do not run.

```ruby
class ApplicationController < BugBunny::Controller
  before_action :authenticate!
  before_action :set_node, only: [:show, :update, :destroy, :drain]

  private

  def authenticate!
    token = request_headers['X-Service-Token']
    render status: :unauthorized, json: { error: 'Unauthorized' } unless valid_token?(token)
  end

  def set_node
    @node = Node.find(params[:id])
    render status: :not_found, json: { error: 'Not found' } unless @node
  end
end
```

---

## after_action

Runs after the action completes successfully. Skipped if a `before_action` halted the chain or if the action raised an exception — same behavior as Rails.

```ruby
class NodesController < ApplicationController
  after_action :emit_audit_event, only: [:create, :update, :destroy]

  private

  def emit_audit_event
    AuditLog.record(action: action_name, node_id: params[:id], actor: current_service)
  end
end
```

---

## around_action

Wraps the action. Must call `yield` to execute the inner chain.

```ruby
class NodesController < ApplicationController
  around_action :with_distributed_lock, only: [:drain]

  private

  def with_distributed_lock
    DistributedLock.acquire("node:#{params[:id]}") { yield }
  end
end
```

---

## rescue_from

Catches exceptions raised during the action and maps them to responses. Handlers are inherited and can be defined in a base `ApplicationController`.

```ruby
class ApplicationController < BugBunny::Controller
  rescue_from ActiveRecord::RecordNotFound do |e|
    render status: :not_found, json: { error: e.message }
  end

  rescue_from ActiveRecord::RecordInvalid do |e|
    render status: :unprocessable_entity, json: { errors: e.record.errors.full_messages }
  end

  rescue_from StandardError do |e|
    logger.error("Unhandled error: #{e.class} — #{e.message}")
    render status: :internal_server_error, json: { error: 'Internal server error' }
  end
end
```

---

## render

```ruby
render status: :ok,                    json: resource.as_json
render status: :created,               json: { id: record.id }
render status: :no_content,            json: nil
render status: :unprocessable_entity,  json: { errors: object.errors }
render status: :not_found,             json: { error: 'Not found' }
```

Accepts any Rack status symbol (`:ok`, `:created`, `:not_found`, etc.) or an integer status code.

### Adding response headers

```ruby
# Per-response headers (merged, non-destructive)
render status: :ok, json: data, headers: { 'X-Request-Id' => request_id }

# Headers set for the lifetime of the action (accessible via response_headers)
def show
  response_headers['X-Cache'] = 'HIT'
  render status: :ok, json: Node.find(params[:id]).as_json
end
```

---

## Accessing AMQP headers

```ruby
def create
  trace_id = request_headers['X-Trace-Id']
  # ...
end
```

`request_headers` returns the raw AMQP headers hash from `properties.headers`.

---

## log_tags

Injects contextual tags into all log lines produced within the action's execution:

```ruby
class NodesController < ApplicationController
  log_tag { params[:id] }
  log_tag { current_tenant }
end
```

Works with Rails' `ActiveSupport::TaggedLogging`.
