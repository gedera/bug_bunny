# frozen_string_literal: true

require 'json'

module BugBunny
  # @api private
  module Observability
    private

    # Registra un evento estructurado. Nunca eleva excepciones.
    #
    # @param level    [Symbol]       Nivel de log (:debug, :info, :warn, :error)
    # @param event    [String]       Nombre del evento en formato "clase.evento"
    # @param metadata [Hash]         Pares clave-valor adicionales
    def safe_log(level, event, metadata = {})
      return unless @logger

      fields = { component: observability_name, event: event }.merge(metadata)

      log_line = fields.map do |k, v|
        val = %i[password token secret api_key auth].include?(k.to_sym) ? "[FILTERED]" : v
        next if val.nil?

        formatted = case val
                    when Numeric then val
                    when Hash    then val.to_json # Genera JSON compacto analizable
                    when String  then val.include?(" ") ? val.inspect : val
                    else val.to_s.include?(" ") ? val.to_s.inspect : val
                    end
        "#{k}=#{formatted}"
      end.compact.join(" ")

      @logger.send(level) { log_line }
    rescue StandardError
    end

    # Genera metadatos estándar para una excepción.
    #
    # @param error [Exception] El objeto de error capturado.
    # @return [Hash] Hash con error_class y error_message truncado.
    def exception_metadata(error)
      {
        error_class: error.class.name,
        error_message: error.message.gsub('"', "'")[0, 200]
      }
    end

    # Timestamp del reloj monotónico para calcular duraciones.
    #
    # @return [Float] Tiempo actual del reloj monotónico.
    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Duración en segundos desde un tiempo de inicio.
    #
    # @param start [Float] Valor devuelto por monotonic_now
    # @return [Float] Duración en segundos redondeada a 6 decimales.
    def duration_s(start)
      (monotonic_now - start).round(6)
    end

    # Infiere el nombre del componente desde el namespace de la clase.
    # Ejemplo: BugBunny::Consumer → "bug_bunny"
    #
    # @return [String] Nombre del componente en snake_case.
    def observability_name
      klass = is_a?(Class) ? self : self.class
      klass.name.split("::").first.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
    rescue StandardError
      "unknown"
    end
  end
end
