# frozen_string_literal: true

require_relative '../test_helper'

class ControllerHeadersTest < Minitest::Test
  # Controlador Dummy para probar headers
  class HeadersController < BugBunny::Controller
    def echo_headers
      # 1. LEER del Request
      client_token = headers['X-Client-Token']

      # 2. ESCRIBIR en el Response
      response_headers['X-Server-Time'] = '123456789'
      response_headers['X-Received-Token'] = client_token

      render status: 200, json: { message: 'ok' }
    end
  end

  def test_headers_flow
    # Simulamos los headers que enviaría el Consumer al Controller
    request_headers = {
      action: 'echo_headers',
      'X-Client-Token' => 'secret_abc'
    }

    # Ejecutamos el pipeline del controlador
    response = HeadersController.call(headers: request_headers, body: {})

    # Verificamos la estructura de la respuesta
    assert_equal 200, response[:status]

    # Verificamos que los headers de respuesta estén presentes
    assert_kind_of Hash, response[:headers]
    assert_equal '123456789', response[:headers]['X-Server-Time']
    assert_equal 'secret_abc', response[:headers]['X-Received-Token']
  end
end
