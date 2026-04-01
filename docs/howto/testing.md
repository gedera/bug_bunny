# Testing

BugBunny applications can be tested at two levels: **unit tests** (with Bunny doubles) and **integration tests** (with a full mocked AMQP stack). No real RabbitMQ server is required.

## Setup

```ruby
# spec/spec_helper.rb
require 'bug_bunny'
require 'rspec'

Dir[File.join(__dir__, 'support', '**', '*.rb')].each { |f| require f }

RSpec.configure do |config|
  config.before(:each) do
    # Reset global state between tests
    BugBunny.instance_variable_set(:@consumer_middlewares, nil)
    BugBunny.instance_variable_set(:@routes, nil)
  end
end
```

---

## Bunny Doubles

Create lightweight doubles for Bunny objects so tests never touch the network:

```ruby
# spec/support/bunny_mocks.rb

def build_bunny_channel(opts = {})
  channel = instance_double(Bunny::Channel)
  allow(channel).to receive(:open?).and_return(true)
  allow(channel).to receive(:prefetch)
  allow(channel).to receive(:confirm_select)
  allow(channel).to receive(:ack)
  allow(channel).to receive(:reject)
  allow(channel).to receive(:close)
  allow(channel).to receive(:default_exchange).and_return(build_bunny_exchange)
  allow(channel).to receive(:topic).and_return(build_bunny_exchange)
  allow(channel).to receive(:direct).and_return(build_bunny_exchange)
  channel
end

def build_bunny_connection(opts = {})
  conn = instance_double(Bunny::Session)
  allow(conn).to receive(:open?).and_return(true)
  allow(conn).to receive(:start)
  allow(conn).to receive(:create_channel).and_return(build_bunny_channel)
  conn
end

def build_bunny_exchange
  exchange = instance_double(Bunny::Exchange)
  allow(exchange).to receive(:publish)
  exchange
end
```

---

## Unit Testing Controllers

Test controller actions directly via `Controller.call`, bypassing AMQP entirely:

```ruby
RSpec.describe NodesController do
  let(:node) { Node.new(id: '42', name: 'web-01', status: 'active') }

  describe '#show' do
    it 'returns the node as JSON' do
      allow(Node).to receive(:find).with('42').and_return(node)

      response = NodesController.call(
        headers: { type: 'nodes/42', 'x-http-method' => 'GET' },
        body: ''
      )

      expect(response[:status]).to eq(200)
      expect(response[:body][:name]).to eq('web-01')
    end
  end

  describe '#show with missing node' do
    it 'returns 404' do
      allow(Node).to receive(:find).with('99').and_return(nil)

      response = NodesController.call(
        headers: { type: 'nodes/99', 'x-http-method' => 'GET' },
        body: ''
      )

      expect(response[:status]).to eq(404)
    end
  end
end
```

---

## Unit Testing before_action / after_action

```ruby
RSpec.describe NodesController do
  describe 'before_action :authenticate!' do
    it 'returns 401 when token is missing' do
      response = NodesController.call(
        headers: { type: 'nodes', 'x-http-method' => 'GET' },
        body: ''
        # no X-Service-Token header
      )

      expect(response[:status]).to eq(401)
    end
  end

  describe 'after_action :emit_audit_event' do
    it 'emits an audit event after create' do
      expect(AuditLog).to receive(:record).with(hash_including(action: 'create'))

      NodesController.call(
        headers: { type: 'nodes', 'x-http-method' => 'POST', 'X-Service-Token' => 'valid' },
        body: '{"node":{"name":"web-01","status":"pending"}}'
      )
    end
  end
end
```

---

## Unit Testing Consumer Middleware

```ruby
RSpec.describe TracingMiddleware do
  subject(:middleware) { described_class.new(terminal) }

  let(:terminal) { ->(di, props, body) { :processed } }
  let(:delivery_info) { instance_double(Bunny::DeliveryInfo, routing_key: 'nodes') }
  let(:properties) do
    instance_double(Bunny::MessageProperties,
      headers: { 'X-Trace-Id' => 'trace-123' },
      correlation_id: 'corr-456'
    )
  end

  it 'extracts the trace header and sets context' do
    expect(MyTracer).to receive(:with_trace).with('trace-123').and_yield

    middleware.call(delivery_info, properties, '{}')
  end

  it 'generates a new trace id when header is absent' do
    allow(properties).to receive(:headers).and_return({})
    expect(MyTracer).to receive(:with_trace).with(be_a(String)).and_yield

    middleware.call(delivery_info, properties, '{}')
  end
end
```

---

## Integration Testing with a Mock Consumer

For tests that exercise the full routing + controller stack, use an in-process integration helper:

```ruby
# spec/support/integration_helper.rb

module IntegrationHelper
  def process_message(method:, path:, body: '', headers: {})
    delivery_info = instance_double(Bunny::DeliveryInfo,
      delivery_tag: 1,
      routing_key: 'test'
    )

    properties = instance_double(Bunny::MessageProperties,
      type: path,
      reply_to: nil,
      correlation_id: SecureRandom.uuid,
      headers: { 'x-http-method' => method.to_s.upcase }.merge(headers)
    )

    consumer = BugBunny::Consumer.new
    # Allow channel operations on the mock session
    allow(consumer.session.channel).to receive(:ack)
    allow(consumer.session.channel).to receive(:reject)
    allow(consumer.session.channel).to receive(:default_exchange).and_return(build_bunny_exchange)

    consumer.send(:process_message, delivery_info, properties, body.to_json)
  end
end

RSpec.configure do |config|
  config.include IntegrationHelper, type: :integration
end
```

```ruby
# spec/integration/nodes_spec.rb, type: :integration
RSpec.describe 'Nodes API', type: :integration do
  before do
    BugBunny.routes.draw { resources :nodes }
  end

  it 'routes GET nodes/:id to NodesController#show' do
    allow(Node).to receive(:find).with('42').and_return(Node.new(id: 42, name: 'web-01'))

    process_message(method: :get, path: 'nodes/42')

    expect(Node).to have_received(:find).with('42')
  end

  it 'returns 404 for unregistered routes' do
    response = process_message(method: :get, path: 'unknown/path')
    # response is captured via the consumer's handle_fatal_error path
  end
end
```

---

## Unit Testing Configuration Validation

```ruby
RSpec.describe BugBunny::Configuration do
  describe '#validate!' do
    it 'raises ConfigurationError when host is blank' do
      config = described_class.new
      config.host = ''

      expect { config.validate! }.to raise_error(BugBunny::ConfigurationError, /host is required/)
    end

    it 'raises ConfigurationError when port is out of range' do
      config = described_class.new
      config.host = 'localhost'
      config.port = 99_999

      expect { config.validate! }.to raise_error(BugBunny::ConfigurationError, /port must be in/)
    end
  end
end
```

---

## Running Tests

```bash
source /opt/homebrew/opt/chruby/share/chruby/chruby.sh && chruby ruby-3.3.8

bundle exec rspec                          # all tests
bundle exec rspec spec/unit/               # unit tests only
bundle exec rspec spec/integration/        # integration tests only
bundle exec rspec spec/unit/consumer_spec.rb  # single file
```
