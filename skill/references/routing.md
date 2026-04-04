# Routing

## DSL Completo

```ruby
BugBunny.routes.draw do
  # Verbos HTTP individuales
  get    'health',       to: 'health#check'
  post   'events',       to: 'events#create'
  put    'settings',     to: 'settings#update'
  patch  'settings',     to: 'settings#patch'
  delete 'cache',        to: 'cache#clear'

  # Resources genera 5 rutas REST
  resources :users
  # GET    users      → UsersController#index
  # GET    users/:id  → UsersController#show
  # POST   users      → UsersController#create
  # PUT    users/:id  → UsersController#update
  # DELETE users/:id  → UsersController#destroy

  # Filtros
  resources :orders, only: [:index, :show]
  resources :products, except: [:destroy]

  # Namespaces (anidables)
  namespace :admin do
    namespace :v2 do
      resources :reports   # → Admin::V2::ReportsController
    end
  end

  # Member y Collection
  resources :nodes do
    member do
      put :drain           # PUT nodes/:id/drain → NodesController#drain
      post :restart        # POST nodes/:id/restart → NodesController#restart
    end
    collection do
      get :stats           # GET nodes/stats → NodesController#stats
      get :health          # GET nodes/health → NodesController#health
    end
  end
end
```

## Route Matching

El `RouteSet#recognize(method, path)` busca la primera ruta que matchee:

- **Normalización:** Strips leading/trailing slashes del path.
- **Parámetros:** `:id` se compila a regex `(?<id>[^/]+)`. Los valores se extraen como Hash.
- **No match:** Retorna `nil` → el consumer responde 404.

```ruby
route = BugBunny.routes.recognize('GET', 'users/42')
route.controller  # => "users"
route.action      # => "show"
route.namespace   # => nil
route.params      # => { 'id' => '42' }
```

## Resolución de Controller

El consumer resuelve el controlador concatenando:
1. `config.controller_namespace` (default: `BugBunny::Controllers`)
2. `route.namespace` (si existe)
3. `route.controller.classify + "Controller"`

Ejemplo: namespace `:admin`, controller `:reports` → `BugBunny::Controllers::Admin::ReportsController`

Valida que el controlador sea subclase de `BugBunny::Controller`. Si no, lanza `SecurityError`.

## Route Object

```ruby
route.http_method       # String: "GET", "POST", etc.
route.path_pattern      # String: "users/:id"
route.controller        # String: "users"
route.action            # String: "show"
route.namespace         # String o nil: "Admin::V2"
```
