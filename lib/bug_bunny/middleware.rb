# lib/bug_bunny/middleware.rb
# frozen_string_literal: true

module BugBunny
  # Clase base para todos los middlewares de BugBunny.
  #
  # Implementa el patrón "Template Method" para estandarizar el flujo de ejecución
  # de la cadena de responsabilidades (Ida y Vuelta).
  #
  # Las subclases deben implementar:
  # * {#on_request} para modificar la petición antes de enviarla.
  # * {#on_complete} para modificar la respuesta después de recibirla.
  #
  # @abstract Subclase y anula {#on_request} o {#on_complete} para inyectar lógica.
  class Middleware
    # @return [Object] El siguiente middleware en la pila o el adaptador final.
    attr_reader :app

    # Inicializa el middleware.
    #
    # @param app [Object] El siguiente eslabón de la cadena.
    def initialize(app)
      @app = app
    end

    # Ejecuta el middleware orquestando los hooks de ciclo de vida.
    #
    # 1. Llama a {#on_request} (Ida).
    # 2. Llama al siguiente eslabón (`@app.call`).
    # 3. Llama a {#on_complete} (Vuelta).
    #
    # @param env [BugBunny::Request] El objeto request (entorno).
    # @return [Hash] La respuesta final procesada.
    def call(env)
      on_request(env) if respond_to?(:on_request)

      response = @app.call(env)

      on_complete(response) if respond_to?(:on_complete)

      response
    end
  end
end
