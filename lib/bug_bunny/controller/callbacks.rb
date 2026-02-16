# frozen_string_literal: true

module BugBunny
  class Controller
    # Módulo que gestiona los filtros (Before Actions) y el manejo de excepciones (Rescue From).
    module Callbacks
      def self.included(base)
        base.extend(ClassMethods)
      end

      # Métodos de clase para DSL.
      module ClassMethods
        # @api private
        def before_actions
          @before_actions ||= Hash.new { |h, k| h[k] = [] }
        end

        # Registra un callback que se ejecutará antes de las acciones.
        def before_action(method_name, **options)
          only = Array(options[:only]).map(&:to_sym)
          target_actions = only.empty? ? [:_all_actions] : only

          target_actions.each do |action|
            before_actions[action] << method_name
          end
        end

        # @api private
        def rescue_handlers
          @rescue_handlers ||= []
        end

        # Registra un manejador para una o más excepciones.
        def rescue_from(*klasses, with: nil, &block)
          handler = with || block
          raise ArgumentError, "Need a handler. Supply 'with: :method' or a block." unless handler

          klasses.each do |klass|
            # Insertamos al principio para prioridad LIFO
            rescue_handlers.unshift([klass, handler])
          end
        end
      end

      private

      # Ejecuta la cadena de filtros before_action.
      # Retorna true si todos pasaron, false si alguno detuvo la ejecución.
      def before_actions_successful?(action_name)
        chain = (self.class.before_actions[:_all_actions] || []) +
                (self.class.before_actions[action_name] || [])

        chain.uniq.each do |method_name|
          send(method_name)
          return false if rendered_response
        end
        true
      end

      # Busca un manejador registrado para la excepción y lo ejecuta.
      def handle_exception(exception)
        handler_entry = find_rescue_handler(exception)

        if handler_entry
          execute_handler(handler_entry, exception)
          return rendered_response if rendered_response
        end

        handle_fatal_error(exception)
      end

      def find_rescue_handler(exception)
        self.class.rescue_handlers.find { |klass, _| exception.is_a?(klass) }
      end

      def execute_handler(entry, exception)
        _, handler = entry
        if handler.is_a?(Symbol)
          send(handler, exception)
        elsif handler.respond_to?(:call)
          instance_exec(exception, &handler)
        end
      end

      def handle_fatal_error(exception)
        BugBunny.configuration.logger.error("Controller Error (#{exception.class}): #{exception.message}")
        BugBunny.configuration.logger.error(exception.backtrace.join("\n"))

        { status: 500, body: { error: exception.message, type: exception.class.name } }
      end
    end
  end
end
