# Routing

Routes declare how incoming AMQP messages map to controllers and actions. They are evaluated on every message received by the Consumer.

## Drawing Routes

Define routes in an initializer (or any file loaded at boot):

```ruby
BugBunny.routes.draw do
  # routes here
end
```

Call `draw` only once. Multiple calls replace the previous route set.

---

## HTTP Verbs

```ruby
BugBunny.routes.draw do
  get    'status',        to: 'health#show'
  post   'events',        to: 'events#create'
  put    'users/:id',     to: 'users#update'
  delete 'users/:id',     to: 'users#destroy'
end
```

The verb is set by the producer via the `x-http-method` AMQP header. `BugBunny::Resource` and `BugBunny::Client` set it automatically.

Dynamic segments (`:id`) are extracted from the path and available in `params` inside the controller.

---

## Resources Macro

`resources` generates the standard seven CRUD routes in one line:

```ruby
resources :users
```

Generates:

| Verb   | Path          | Action    |
|--------|---------------|-----------|
| GET    | users         | index     |
| POST   | users         | create    |
| GET    | users/:id     | show      |
| PUT    | users/:id     | update    |
| DELETE | users/:id     | destroy   |

### Filtering actions

```ruby
resources :orders, only: [:index, :show, :create]
resources :logs,   except: [:update, :destroy]
```

---

## Member and Collection Routes

```ruby
resources :nodes do
  member do
    put  :drain      # PUT  nodes/:id/drain   → NodesController#drain
    post :reboot     # POST nodes/:id/reboot  → NodesController#reboot
  end

  collection do
    post :rebalance  # POST nodes/rebalance   → NodesController#rebalance
    get  :summary    # GET  nodes/summary     → NodesController#summary
  end
end
```

Member routes receive `params[:id]` automatically. Collection routes do not.

---

## Namespace Blocks

Group routes under a controller namespace. Namespaces stack: nested `namespace` blocks accumulate with `::`.

```ruby
BugBunny.routes.draw do
  namespace :api do
    namespace :v1 do
      resources :metrics     # → Api::V1::MetricsController
      resources :alerts      # → Api::V1::AlertsController
    end

    resources :health        # → Api::HealthController
  end

  resources :nodes           # → BugBunny::Controllers::NodesController (global namespace)
end
```

The namespace in the route takes precedence over `config.controller_namespace`. Routes without a namespace block use the global controller namespace.

---

## Nested Resources

```ruby
resources :clusters do
  resources :nodes do        # → nodes/:id nested under clusters/:cluster_id
    member { put :drain }
  end
end
```

Nested resource routes inject all parent IDs into params. Example: `PUT clusters/c1/nodes/n2/drain` → `params[:cluster_id] = 'c1'`, `params[:id] = 'n2'`.

---

## Inspecting Routes

```ruby
BugBunny.routes.recognize('GET', 'nodes/123')
# => { controller: 'nodes', action: 'show', params: { 'id' => '123' }, namespace: nil }

BugBunny.routes.recognize('POST', 'api/v1/metrics')
# => { controller: 'metrics', action: 'create', params: {}, namespace: 'Api::V1' }

BugBunny.routes.recognize('GET', 'unknown/path')
# => nil
```

Useful in tests to verify route definitions without sending real messages.
