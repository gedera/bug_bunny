# Testing

## Estructura

```
spec/
├── spec_helper.rb
├── support/
│   ├── bunny_mocks.rb          # Stubs para unit tests
│   └── integration_helper.rb   # Helpers para integration tests
├── unit/                       # Sin RabbitMQ real
│   ├── configuration_spec.rb
│   ├── client_session_pool_spec.rb
│   ├── consumer_spec.rb
│   ├── session_spec.rb
│   ├── consumer_middleware_spec.rb
│   ├── controller_after_action_spec.rb
│   ├── observability_spec.rb
│   └── resource_attributes_spec.rb
└── integration/                # Requiere RabbitMQ
    ├── client_spec.rb
    ├── consumer_middleware_spec.rb
    ├── controller_spec.rb
    ├── error_handling_spec.rb
    ├── infrastructure_spec.rb
    └── resource_spec.rb
```

## Unit Tests — Mocking de Bunny

Los unit tests usan `BunnyMocks` para evitar dependencia de RabbitMQ:

```ruby
# spec/support/bunny_mocks.rb
BunnyMocks::FakeChannel     # Simula canal Bunny
BunnyMocks::FakeConnection  # Simula conexión Bunny
```

Patrón de uso:

```ruby
let(:connection) { BunnyMocks::FakeConnection.new }
let(:session) { BugBunny::Session.new(connection) }
```

Para Producer: `allow_any_instance_of(BugBunny::Producer).to receive(:rpc).and_return(response)`

## Integration Tests — Helpers

### with_running_worker

Levanta un consumer real en un thread:

```ruby
with_running_worker(
  queue: unique('test_q'),
  exchange: unique('test_ex'),
  exchange_type: 'topic',
  routing_key: 'users.#'
) do
  response = client.request('users/1', method: :get)
  expect(response['status']).to eq(200)
end
# Worker se detiene automáticamente al salir del bloque
```

### with_spy_worker

Captura mensajes sin procesarlos:

```ruby
with_spy_worker(queue:, exchange:) do |messages|
  client.publish('events', body: { type: 'test' })
  msg = wait_for_message(messages, 5)
  expect(msg[:body]).to include('type' => 'test')
end
```

### unique(name)

Genera nombres únicos para evitar colisiones entre tests:

```ruby
unique('my_queue')  # → "my_queue_a3f1b2c4"
# Usa SecureRandom.hex(4)
```

## Thread Safety Testing

Patrón con `Concurrent::CyclicBarrier`:

```ruby
barrier = Concurrent::CyclicBarrier.new(10)
counter = Concurrent::AtomicFixnum.new(0)

threads = 10.times.map do
  Thread.new do
    barrier.wait   # Sincroniza inicio
    session.channel
    counter.increment
  end
end

threads.each(&:join)
expect(counter.value).to eq(10)
```

## Skip de Integration Tests

Los tests `:integration` se skipean automáticamente si RabbitMQ no está disponible:

```ruby
# spec_helper.rb
config.before(:each, :integration) do
  skip 'RabbitMQ not available' unless rabbitmq_available?
end
```

## Configuración de Test

```ruby
BugBunny.configure do |config|
  config.host     = ENV.fetch('RABBITMQ_HOST', 'localhost')
  config.username = ENV.fetch('RABBITMQ_USER', 'guest')
  config.password = ENV.fetch('RABBITMQ_PASS', 'guest')
end

TEST_POOL = ConnectionPool.new(size: 5) { BugBunny.create_connection }
```

## Ejecutar Tests

```bash
bundle exec rspec                           # Todos
bundle exec rspec spec/unit/                # Solo unit
bundle exec rspec spec/integration/         # Solo integration (requiere RabbitMQ)
bundle exec rspec spec/unit/session_spec.rb # Archivo específico
```
