# frozen_string_literal: true

module BugBunny
  class Resource
    # Módulo encargado de las operaciones de persistencia (CRUD).
    #
    # Este módulo implementa la lógica de `save`, `update` y `destroy`, gestionando
    # el ciclo de vida de los callbacks de ActiveModel y el manejo de errores
    # retornados por el servicio remoto (RabbitMQ).
    module Persistence
      # Guarda el registro en el servicio remoto.
      #
      # Ejecuta las validaciones locales y los callbacks `:save`. Si el registro
      # ya está persistido, realiza una actualización (PUT), de lo contrario crea
      # uno nuevo (POST).
      #
      # @return [Boolean] `true` si se guardó correctamente, `false` si hubo errores de validación o del servidor.
      def save
        return false unless valid?

        run_callbacks(:save) do
          persisted? ? perform_update : perform_create
          true
        end
      rescue BugBunny::UnprocessableEntity => e
        load_remote_rabbit_errors(e.error_messages)
        false
      end

      # Elimina el registro del servicio remoto.
      #
      # Ejecuta los callbacks `:destroy` y envía una petición DELETE.
      # Marca la instancia como no persistida si la operación es exitosa.
      #
      # @return [Boolean] `true` si se eliminó correctamente.
      def destroy
        return false unless persisted?

        run_callbacks(:destroy) do
          perform_destroy
        end
        true
      rescue BugBunny::ServerError, BugBunny::ClientError
        false
      end

      private

      # Ejecuta la lógica interna de creación (POST).
      def perform_create
        rk = calculate_routing_key(id)
        body = { self.class.param_key => changes_to_send }
        resp = bug_bunny_client.request(self.class.resource_name, method: :post, exchange: current_exchange,
                                                                  exchange_type: current_exchange_type,
                                                                  routing_key: rk, body: body)
        load_response_data(resp)
      end

      # Ejecuta la lógica interna de actualización (PUT).
      def perform_update
        rk = calculate_routing_key(id)
        body = { self.class.param_key => changes_to_send }
        path = "#{self.class.resource_name}/#{id}"
        resp = bug_bunny_client.request(path, method: :put, exchange: current_exchange,
                                              exchange_type: current_exchange_type,
                                              routing_key: rk, body: body)
        load_response_data(resp)
      end

      # Ejecuta la lógica interna de eliminación (DELETE).
      # Extraído para cumplir con métricas de longitud de método.
      def perform_destroy
        rk = calculate_routing_key(id)
        path = "#{self.class.resource_name}/#{id}"
        bug_bunny_client.request(path, method: :delete, exchange: current_exchange,
                                       exchange_type: current_exchange_type, routing_key: rk)
        self.persisted = false
      end

      # Carga los datos de la respuesta en la instancia actual.
      # Actualiza atributos, marca como persistido y limpia cambios (Dirty tracking).
      #
      # @param response [Hash] La respuesta cruda del cliente RPC.
      def load_response_data(response)
        check_response_errors(response)
        assign_attributes(response['body'])
        self.persisted = true
        clear_changes_information
      end

      # Verifica el código de estado HTTP simulado en la respuesta.
      # @raise [BugBunny::UnprocessableEntity] Si es 422.
      # @raise [BugBunny::InternalServerError] Si es 5xx.
      # @raise [BugBunny::ClientError] Si es 4xx.
      def check_response_errors(response)
        status = response['status']
        if status == 422
          raise BugBunny::UnprocessableEntity, (response['body']['errors'] || response['body'])
        elsif status >= 500
          raise BugBunny::InternalServerError
        elsif status >= 400
          raise BugBunny::ClientError
        end
      end

      # Mapea los errores recibidos del servidor remoto al objeto local `errors`.
      #
      # @param errors_hash [Hash, String] Errores devueltos por la API remota.
      def load_remote_rabbit_errors(errors_hash)
        return if errors_hash.nil?

        if errors_hash.is_a?(String)
          errors.add(:base, errors_hash)
        else
          errors_hash.each { |attr, msg| Array(msg).each { |m| errors.add(attr, m) } }
        end
      end
    end
  end
end
