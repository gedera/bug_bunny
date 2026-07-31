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

    # Alternación de keys sensibles ordenada de más larga a más corta: en un regex
    # la alternación matchea leftmost-first, así que sin este orden `auth` ganaría
    # sobre `authorization` y el patrón dejaría de matchear (`orization=x` no sigue
    # con `[:=]`).
    SENSITIVE_KEYS_ALTERNATION = SENSITIVE_KEYS.sort_by { |k| -k.length }.join('|').freeze

    # Reglas de VALOR sensible, como pares `[regex, reemplazo]`.
    #
    # {.sensitive_key?} solo ve el NOMBRE de la clave; no puede ver una credencial
    # embebida en TEXTO LIBRE. El caso canónico es el `message` de una excepción
    # inesperada (llega como `reason=` o `error_message=`, nombres no sensibles):
    # un `NoMethodError` sobre un objeto de respuesta HTTP puede arrastrar
    # `Authorization: "Bearer eyJ..."` en su mensaje y el filtro por-clave lo deja
    # pasar entero al log.
    #
    # El reemplazo conserva el nombre de la clave cuando viaja dentro del texto
    # (`token=[FILTERED]`, no `[FILTERED]`): saber QUÉ credencial apareció es
    # diagnóstico útil; su valor no.
    SENSITIVE_VALUE_RULES = [
      # Esquemas de autenticación HTTP: "Bearer <jwt>", "Basic <base64>".
      [/\b(?:bearer|basic)\s+[A-Za-z0-9\-._~+\/]{8,}={0,2}/i, '[FILTERED]'],
      # La key viaja DENTRO del texto: `token=abc`, `password: 'x'`, `"api_key" => "y"`.
      #
      # El prefijo `\w*` va en lugar de un `\b`: `_` es word-char, así que un borde de
      # palabra NO existe dentro de `access_token` ni de `accessToken` y esas variantes
      # se colarían en claro — justo las que {.sensitive_key?} cubre a propósito con
      # substring matching. Se captura el prefijo para conservar el nombre COMPLETO de la
      # key en el log (`access_token=[FILTERED]`): saber qué credencial apareció es
      # diagnóstico útil. No reintroduce el falso positivo de `passport_number` porque
      # ninguna key de SENSITIVE_KEYS es substring suyo (por eso `pass` bare está excluida).
      [/(\w*(?:#{SENSITIVE_KEYS_ALTERNATION}))["']?\s*(?:=>|[:=])\s*["']?[^\s,;"'}\])]+/i,
       '\1=[FILTERED]'],
      # Credenciales en una URL: `amqp://user:pass@host` → conserva el esquema y el host.
      [%r{(://)[^\s/:@]+:[^\s/@]+@}, '\1[FILTERED]@']
    ].freeze

    # Redacta credenciales embebidas en un valor de texto libre.
    #
    # Complementa a {.sensitive_key?}: esa filtra por NOMBRE de clave, esta por
    # CONTENIDO. Se aplica a todo valor no numérico que {#safe_log} serializa.
    #
    # @param value [Object] El valor a redactar (se serializa con `to_s`).
    # @return [String] El valor con las credenciales reemplazadas por `[FILTERED]`.
    def self.redact_value(value)
      SENSITIVE_VALUE_RULES.reduce(value.to_s) do |acc, (pattern, replacement)|
        acc.gsub(pattern, replacement)
      end
    end

    # Redacta una estructura ANTES de serializarla, recorriendo keys y valores.
    #
    # Se usa para los valores `Hash` de {#safe_log}. Redactar el JSON ya serializado con
    # {.redact_value} no sirve: la regla de key-dentro-del-texto normaliza el separador a
    # `=` y se come la comilla de cierre de la key, dejando `{"token=[FILTERED]",...}` —
    # el secreto desaparece, pero el campo deja de ser JSON parseable y quien consume el
    # log pierde el objeto entero.
    #
    # Recorriendo la estructura, además, las keys internas SÍ pasan por {.sensitive_key?}
    # (que solo veía las keys de primer nivel del metadata).
    #
    # @param obj [Object] Estructura a redactar (Hash/Array anidados incluidos).
    # @return [Object] La misma forma, con los valores sensibles reemplazados.
    def self.redact_structure(obj)
      case obj
      when Hash
        obj.each_with_object({}) do |(k, v), acc|
          acc[k] = sensitive_key?(k) ? '[FILTERED]' : redact_structure(v)
        end
      when Array then obj.map { |element| redact_structure(element) }
      when Numeric, TrueClass, FalseClass, NilClass then obj
      else redact_value(obj)
      end
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

        # La redacción por CONTENIDO se aplica a todo valor no numérico: el filtro
        # por-clave de arriba no ve una credencial embebida en texto libre.
        formatted = case val
                    when Numeric then val
                    when Hash
                      # Se redacta la estructura y DESPUÉS se serializa: al revés el campo
                      # queda con el secreto tapado pero el JSON roto (ver .redact_structure).
                      BugBunny::Observability.redact_structure(val).to_json
                    else
                      redacted = BugBunny::Observability.redact_value(val)
                      redacted.include?(' ') ? redacted.inspect : redacted
                    end
        "#{k}=#{formatted}"
      end.compact.join(' ')

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
      klass.name.split('::').first.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
    rescue StandardError
      'unknown'
    end
  end
end
