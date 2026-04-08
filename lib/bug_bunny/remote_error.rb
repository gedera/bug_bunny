# frozen_string_literal: true

module BugBunny
  # Error 500 especial que propagationa información de una excepción remota.
  #
  # Cuando un controller levanta una excepción no manejada en el worker, esta clase
  # permite al llamador RPC acceder a:
  # - La clase original de la excepción (ej: ActiveRecord::RecordNotFound)
  # - El mensaje original
  # - El backtrace completo para debugging
  #
  # Mantiene compatibilidad hacia atrás: si la respuesta no contiene
  # bug_bunny_exception, se comporta como un InternalServerError común.
  class RemoteError < ServerError
    # @return [String] La clase de la excepción remota (ej: 'ActiveRecord::RecordNotFound').
    attr_reader :original_class

    # @return [String] El mensaje original de la excepción.
    attr_reader :original_message

    # @return [Array<String>] El backtrace original de la excepción.
    attr_reader :original_backtrace

    # Serializa una excepción para transmitirse como parte de la respuesta.
    #
    # @param exception [StandardError] La excepción a serializar.
    # @param max_lines [Integer] Máximo de líneas del backtrace (default 25).
    # @return [Hash] Estructura con class, message y backtrace.
    def self.serialize(exception, max_lines: 25)
      {
        class: exception.class.name,
        message: exception.message,
        backtrace: exception.backtrace&.first(max_lines) || []
      }
    end

    # Inicializa la excepción remota propagada desde el worker.
    #
    # @param original_class [String] Nombre completo de la clase de la excepción.
    # @param message [String] Mensaje de la excepción.
    # @param backtrace [Array<String>] Stack trace completo.
    def initialize(original_class, message, backtrace)
      @original_class = original_class
      @original_message = message
      @original_backtrace = backtrace || []
      super(message)
      set_backtrace(backtrace || [])
    end

    # @return [String] Representación legible de la excepción.
    def to_s
      "#{self.class.name}(#{original_class}): #{super}"
    end
  end
end
