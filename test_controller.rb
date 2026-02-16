# frozen_string_literal: true

# test_controller.rb
require 'active_support/all'
require 'rack'
require_relative 'lib/bug_bunny'

module Rabbit
  module Controllers
    # Nota: BugBunny buscará "TestUser" -> Rabbit::Controllers::TestUser
    class TestUser < BugBunny::Controller
      # GET /show (Simulado)
      # Usado por TestUser.find(1)
      def show
        puts " [API] 🔍 Buscando usuario ID: #{params[:id]}"
        if params[:id].to_i == 999
          # Simulamos un 404
          render status: 404, json: { error: 'User not found' }
        else
          render status: 200, json: {
            id: params[:id].to_i,
            name: 'Gabriel',
            email: 'gabriel@test.com',
            persisted: true
          }
        end
      end

      # POST /create
      # Usado por TestUser.create(...)
      def create
        puts " [API] 💾 Creando usuario: #{params.inspect}"

        # Simulamos guardado
        new_id = rand(1000..9999)

        render status: 201, json: {
          id: new_id,
          name: params[:name],
          email: params[:email],
          created_at: Time.now
        }
      end

      # Acción custom (RPC manual)
      def ping
        render status: 200, json: { message: 'Pong!' }
      end
    end
  end
end
