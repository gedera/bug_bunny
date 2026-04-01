# frozen_string_literal: true

module BugBunny
  # Infraestructura de middleware para el Consumer AMQP.
  #
  # Permite inyectar lógica transversal (tracing, autenticación, logging) en el
  # pipeline de procesamiento de mensajes, antes de que la gema procese el mensaje.
  #
  # Cada middleware recibe `(delivery_info, properties, body)` y debe llamar a
  # `@app.call(delivery_info, properties, body)` para continuar la cadena.
  #
  # @example Registrar un middleware desde una gema externa (auto-registro al hacer require)
  #   BugBunny.consumer_middlewares.use MyTracing::ConsumerMiddleware
  #
  # @example Implementar un middleware propio
  #   class MyMiddleware < BugBunny::ConsumerMiddleware::Base
  #     def call(delivery_info, properties, body)
  #       # lógica pre-procesamiento (ej: hidratar contexto de tracing)
  #       @app.call(delivery_info, properties, body)
  #       # lógica post-procesamiento
  #     end
  #   end
  module ConsumerMiddleware
    # Clase base para middlewares del Consumer.
    #
    # @abstract Subclasificá e implementá {#call}.
    class Base
      # @param app [#call] El siguiente eslabón en la cadena (otro middleware o el core).
      def initialize(app)
        @app = app
      end

      # Procesa el mensaje y delega al siguiente eslabón.
      #
      # @param delivery_info [Bunny::DeliveryInfo] Metadatos de entrega AMQP.
      # @param properties [Bunny::MessageProperties] Headers y propiedades AMQP.
      # @param body [String] Payload crudo del mensaje.
      # @return [void]
      def call(delivery_info, properties, body)
        @app.call(delivery_info, properties, body)
      end
    end

    # Gestiona y ejecuta la cadena de middlewares del Consumer.
    #
    # Thread-safe: `use` y `empty?` están protegidos por un Mutex. `call` toma un
    # snapshot del array bajo mutex y ejecuta la cadena fuera del lock para no
    # serializar el procesamiento de mensajes.
    class Stack
      def initialize
        @middlewares = []
        @mutex = Mutex.new
      end

      # Registra un middleware en la cadena. Thread-safe.
      #
      # @param middleware_class [Class] Clase que hereda de {Base}.
      # @return [self]
      def use(middleware_class)
        @mutex.synchronize { @middlewares << middleware_class }
        self
      end

      # @return [Boolean] `true` si no hay middlewares registrados. Thread-safe.
      def empty?
        @mutex.synchronize { @middlewares.empty? }
      end

      # Ejecuta la cadena de middlewares envolviendo el bloque core.
      #
      # Toma un snapshot del array de middlewares bajo mutex y construye la cadena
      # fuera del lock para no bloquear registros concurrentes durante la ejecución.
      #
      # @param delivery_info [Bunny::DeliveryInfo]
      # @param properties [Bunny::MessageProperties]
      # @param body [String]
      # @yieldreturn [void] El bloque core a ejecutar al final de la cadena.
      # @return [void]
      def call(delivery_info, properties, body, &core)
        snapshot = @mutex.synchronize { @middlewares.dup }
        terminal = ->(_di, _props, _body) { core.call }

        chain = snapshot.reverse.inject(terminal) do |next_step, middleware_class|
          middleware_class.new(next_step)
        end

        chain.call(delivery_info, properties, body)
      end
    end
  end
end
