# frozen_string_literal: true

require 'active_model'
require 'rack'
require_relative 'controller/callbacks'

module BugBunny
  # Clase base para Controladores de Mensajes.
  class Controller
    include ActiveModel::Model
    include ActiveModel::Attributes
    include Callbacks

    # @return [Hash] Metadatos del mensaje (headers AMQP, routing info).
    attribute :headers

    # @return [ActiveSupport::HashWithIndifferentAccess] Parámetros unificados.
    attribute :params

    # @return [String] Cuerpo crudo si el payload no es JSON.
    attribute :raw_string

    # @return [Hash, nil] La respuesta renderizada { status, body }.
    attr_reader :rendered_response

    # Punto de entrada principal llamado por el Consumer.
    def self.call(headers:, body: {})
      new(headers: headers).process(body)
    end

    # Ejecuta el ciclo de vida de la petición: Params -> Filtros -> Acción.
    def process(body)
      prepare_params(body)
      action_name = headers[:action].to_sym

      # 1. Ejecutar Before Actions (si retorna false, hubo render/halt)
      return rendered_response unless before_actions_successful?(action_name)

      # 2. Ejecutar Acción
      raise NameError, "Action '#{action_name}' not found in #{self.class.name}" unless respond_to?(action_name)

      public_send(action_name)

      # 3. Respuesta por defecto (204 No Content) si la acción no llamó a render
      rendered_response || { status: 204, body: nil }
    rescue StandardError => e
      handle_exception(e)
    end

    private

    # Construye la respuesta RPC normalizada.
    def render(status:, json: nil)
      code = Rack::Utils::SYMBOL_TO_STATUS_CODE[status] || 200
      @rendered_response = { status: code, body: json }
    end

    # Normaliza y fusiona parámetros de múltiples fuentes.
    def prepare_params(body)
      self.params = {}.with_indifferent_access
      merge_header_params
      merge_body_params(body)
    end

    def merge_header_params
      params.merge!(headers[:query_params]) if headers[:query_params].present?
      params[:id] = headers[:id] if headers[:id].present?
    end

    def merge_body_params(body)
      if body.is_a?(Hash)
        params.merge!(body)
      elsif body.is_a?(String) && json_content_type?
        merge_json_body(body)
      else
        self.raw_string = body
      end
    end

    def json_content_type?
      headers[:content_type].to_s.include?('json')
    end

    def merge_json_body(body)
      parsed = parse_json_safely(body)
      params.merge!(parsed) if parsed
    end

    def parse_json_safely(json_string)
      JSON.parse(json_string)
    rescue StandardError
      nil
    end
  end
end
