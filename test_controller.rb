# test_controller.rb
require 'active_support/all'
require_relative 'lib/bug_bunny'

# Namespace obligatorio: Rabbit::Controllers
module Rabbit
  module Controllers
    class Test < BugBunny::Controller
      # Acción: ping
      # Ruta: 'test/ping' o 'test/99/ping'
      def ping
        # Simulamos un proceso
        puts " [Controller] ⚙️ Procesando acción 'ping'..."
        puts "              Params recibidos: #{params.inspect}"

        # Respuesta JSON estándar
        render status: 200, json: {
          message: "Pong desde el Worker!",
          received_id: params[:id],
          timestamp: Time.now.to_i
        }
      end
    end
  end
end
