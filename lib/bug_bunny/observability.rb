# frozen_string_literal: true

require 'json'

module BugBunny
  # @api private
  module Observability
    # Patrones de keys que deben ser ocultados en los logs.
    # Se usa substring matching en lowercase para cubrir variantes como
    # "user_password", "accessToken", "X-Authorization", etc.
    # Excluye "pass" y "session" bare para evitar falsos positivos
    # en keys como "passport_number" o "processing_session_count".
    SENSITIVE_KEYS = %w[
      password passwd secret token api_key auth authorization
      credential private_key csrf session_id
    ].freeze

    # Determina si una key es sensible y debe filtrarse en los logs.
    # Accesible como método de módulo para que otros componentes puedan reutilizarlo.
    #
    # @param key [String, Symbol] La clave a evaluar.
    # @return [Boolean] `true` si la key es sensible.
    def self.sensitive_key?(key)
      # Normalize hyphens → underscores so HTTP headers like "X-Api-Key"
      # match the same patterns as Ruby symbol keys like :api_key.
      key_str = key.to_s.downcase.tr('-', '_')
      SENSITIVE_KEYS.any? { |sensitive| key_str.include?(sensitive) }
    end

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
        val = BugBunny::Observability.sensitive_key?(k) ? '[FILTERED]' : v
        next if val.nil?

        formatted = case val
                    when Numeric then val
                    when Hash
                      val.to_json
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
