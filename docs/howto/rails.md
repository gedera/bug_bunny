# Rails Setup

Complete integration guide for BugBunny in a Rails application using Puma and/or Sidekiq.

## Gemfile

```ruby
gem 'bug_bunny'
gem 'connection_pool'
```

## Generator

```bash
rails generate bug_bunny:install
```

Creates `config/initializers/bug_bunny.rb` with a commented template.

---

## Initializer

```ruby
# config/initializers/bug_bunny.rb

BugBunny.configure do |config|
  config.host     = ENV.fetch('RABBITMQ_HOST', 'localhost')
  config.port     = ENV.fetch('RABBITMQ_PORT', '5672').to_i
  config.username = ENV.fetch('RABBITMQ_USER', 'guest')
  config.password = ENV.fetch('RABBITMQ_PASS', 'guest')
  config.vhost    = ENV.fetch('RABBITMQ_VHOST', '/')

  config.rpc_timeout               = 30
  config.max_reconnect_attempts    = 10
  config.max_reconnect_interval    = 60
  config.network_recovery_interval = 5

  config.exchange_options = { durable: true }
  config.queue_options    = { durable: true }

  config.logger = Rails.logger

  # Kubernetes / Docker Swarm liveness probe
  config.health_check_file = Rails.root.join('tmp', 'bug_bunny_health').to_s
end

# Shared connection pool — size should match Puma/Sidekiq thread count
BUG_BUNNY_POOL = ConnectionPool.new(
  size:    ENV.fetch('RAILS_MAX_THREADS', 5).to_i,
  timeout: 5
) do
  BugBunny.create_connection
end

# Make the pool available to all Resource classes
BugBunny::Resource.connection_pool = BUG_BUNNY_POOL
```

---

## Routes

```ruby
# config/initializers/bug_bunny_routes.rb
BugBunny.routes.draw do
  resources :users
  resources :orders do
    member { post :cancel }
  end
end
```

Keep routes in a dedicated initializer so they load independently from `config/routes.rb`.

---

## Directory Layout

The Rails generator configures Zeitwerk to autoload `app/rabbit`:

```
app/
  rabbit/
    controllers/          # BugBunny controllers (loaded under BugBunny::Controllers)
      application_controller.rb
      users_controller.rb
    workers/              # Consumer processes (optional)
      inventory_worker.rb
```

Or use the configurable controller namespace:

```ruby
config.controller_namespace = 'Rabbit::Controllers'
# → app/rabbit/controllers/ maps to Rabbit::Controllers
```

---

## Consumer Workers

The Consumer is a blocking subscribe loop. Run it in a dedicated process (not inside Puma).

### Rake task

```ruby
# lib/tasks/rabbit.rake
namespace :rabbit do
  desc 'Start the RabbitMQ consumer'
  task inventory: :environment do
    consumer = BugBunny::Consumer.new
    trap('TERM') { consumer.shutdown; exit }
    trap('INT')  { consumer.shutdown; exit }

    consumer.subscribe(
      queue_name:    'inventory_queue',
      exchange_name: 'inventory_exchange',
      routing_key:   'inventory',
      block:         true
    )
  end
end
```

```bash
bundle exec rake rabbit:inventory
```

### Dockerfile entrypoint (separate service)

```dockerfile
# Dockerfile.worker
CMD ["bundle", "exec", "rake", "rabbit:inventory"]
```

### Multiple consumers

Run one process per queue. Each process has its own connection pool.

---

## Puma Fork Safety

When Puma forks workers, open AMQP connections in the parent process become invalid in children. BugBunny's Railtie handles this automatically for Puma via `on_worker_boot`:

```ruby
# Railtie registers this automatically:
Puma::Server.on_worker_boot do
  BugBunny.reconnect! if defined?(BUG_BUNNY_POOL)
end
```

If you use a custom pool variable name, add the hook manually:

```ruby
# config/puma.rb
on_worker_boot do
  MY_CUSTOM_POOL.reload_connections { BugBunny.create_connection }
end
```

---

## Sidekiq Integration

Sidekiq uses threads, not forks, so no special handling is needed. The shared `BUG_BUNNY_POOL` is thread-safe. Sidekiq jobs can call `BugBunny::Resource` methods directly.

Set the pool size to match Sidekiq's concurrency:

```ruby
BUG_BUNNY_POOL = ConnectionPool.new(
  size: ENV.fetch('SIDEKIQ_CONCURRENCY', 10).to_i,
  timeout: 5
) { BugBunny.create_connection }
```

---

## Health Checks (Kubernetes / Docker Swarm)

The Consumer's internal heartbeat timer touches `config.health_check_file` every 30 seconds after verifying the RabbitMQ connection and queue are alive.

```yaml
# docker-compose.yml
healthcheck:
  test: ["CMD", "test", "-f", "/app/tmp/bug_bunny_health"]
  interval: 60s
  timeout: 5s
  retries: 3
  start_period: 30s  # allow time for Rails boot + first heartbeat
```

```yaml
# Kubernetes
livenessProbe:
  exec:
    command: ["test", "-f", "/app/tmp/bug_bunny_health"]
  initialDelaySeconds: 30
  periodSeconds: 60
```

---

## Graceful Shutdown

The `Consumer#shutdown` method stops the heartbeat timer and closes the AMQP channel cleanly. It is also called automatically when `subscribe` exits for any reason.

```ruby
consumer = BugBunny::Consumer.new
trap('TERM') { consumer.shutdown; exit 0 }
trap('INT')  { consumer.shutdown; exit 0 }
consumer.subscribe(...)
```
