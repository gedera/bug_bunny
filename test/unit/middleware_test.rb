# frozen_string_literal: true

require_relative '../test_helper'

class MiddlewareTest < Minitest::Test
  # Middleware dummy para rastrear ejecución
  class TrackerMiddleware < BugBunny::Middleware::Base
    def on_request(env)
      env[:trace] << 'req_in'
    end

    def on_complete(response)
      response[:trace] << 'res_out'
    end
  end

  def setup
    @stack = BugBunny::Middleware::Stack.new
  end

  def test_execution_order
    # La "App" final (Producer)
    final_app = ->(env) {
      env[:trace] << 'executing'
      { body: 'ok', trace: env[:trace] }
    }

    @stack.use TrackerMiddleware
    chain = @stack.build(final_app)

    env = { trace: [] }
    response = chain.call(env)

    # El orden debe ser: Entrada -> Ejecución -> Salida (Cebolla)
    expected_trace = ['req_in', 'executing', 'res_out']
    assert_equal expected_trace, response[:trace]
  end

  def test_json_response_parsing
    # Simulamos una respuesta JSON cruda
    app = ->(_) { { 'body' => '{"foo":"bar"}', 'status' => 200 } }

    middleware = BugBunny::Middleware::JsonResponse.new(app)
    response = middleware.call({})

    # Debe convertirse en Hash
    assert_kind_of Hash, response['body']
    assert_equal 'bar', response['body']['foo']
  end

  def test_raise_error_handling
    # Simulamos un error 404
    app = ->(_) { { 'status' => 404, 'body' => 'Not Found' } }

    middleware = BugBunny::Middleware::RaiseError.new(app)

    assert_raises(BugBunny::NotFound) do
      middleware.call({})
    end
  end
end
