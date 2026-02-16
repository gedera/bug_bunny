# frozen_string_literal: true

require_relative 'lib/bug_bunny'
require_relative 'test_resource'

module Rabbit
  module Controllers
    # Controlador de prueba para verificar el enrutamiento y despacho.
    class TestUser < BugBunny::Controller
      # Acción ping (GET /test_user/ping)
      def ping
        render status: 200, json: { message: 'Pong!' }
      end

      # Acción show (GET /test_user/:id)
      # Se refactorizó para cumplir con Metrics/MethodLength
      def show
        id = params[:id].to_i
        # Simulamos una base de datos
        if id == 123
          render_found_user(id)
        else
          render status: 404, json: { error: 'User not found' }
        end
      end

      # Acción create (POST /test_user)
      def create
        # SIMULACIÓN: Rechazar emails que terminen en .org aunque sean válidos localmente
        # Esto permite probar el manejo de errores 422 en el cliente.
        if params[:test_user][:email].end_with?('.org')
          render status: 422, json: { errors: { email: ['no se permiten .org'] } }
          return
        end

        user = ::TestUser.new(params[:test_user])
        if user.valid?
          user.id = rand(1000..9999) # Simular ID autogenerado
          render status: 201, json: user.remote_attributes
        else
          render status: 422, json: { errors: user.errors.messages }
        end
      end

      private

      def render_found_user(id)
        render status: 200, json: {
          id: id,
          name: 'Gabriel',
          email: 'gab.edera@gmail.com',
          created_at: Time.now.iso8601
        }
      end
    end
  end
end
