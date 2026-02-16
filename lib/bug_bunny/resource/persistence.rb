# frozen_string_literal: true

module BugBunny
  class Resource
    # Módulo para operaciones de persistencia CRUD (Create, Update, Destroy).
    module Persistence
      # Guarda el registro remotamente.
      # Ejecuta validaciones y callbacks antes de enviar la petición.
      #
      # @return [Boolean] true si se guardó con éxito, false si hubo errores.
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

      # Elimina el registro remotamente.
      #
      # @return [Boolean] true si se eliminó, false si falló.
      def destroy
        return false unless persisted?

        run_callbacks(:destroy) do
          rk = calculate_routing_key(id)
          path = "#{self.class.resource_name}/#{id}"
          bug_bunny_client.request(path, method: :delete, exchange: current_exchange,
                                         exchange_type: current_exchange_type, routing_key: rk)
          self.persisted = false
        end
        true
      rescue BugBunny::ServerError, BugBunny::ClientError
        false
      end

      private

      def perform_create
        rk = calculate_routing_key(id)
        body = { self.class.param_key => changes_to_send }
        resp = bug_bunny_client.request(self.class.resource_name, method: :post, exchange: current_exchange,
                                                                  exchange_type: current_exchange_type,
                                                                  routing_key: rk, body: body)
        load_response_data(resp)
      end

      def perform_update
        rk = calculate_routing_key(id)
        body = { self.class.param_key => changes_to_send }
        path = "#{self.class.resource_name}/#{id}"
        resp = bug_bunny_client.request(path, method: :put, exchange: current_exchange,
                                              exchange_type: current_exchange_type,
                                              routing_key: rk, body: body)
        load_response_data(resp)
      end

      # Carga los datos de la respuesta en la instancia actual.
      # @api private
      def load_response_data(response)
        check_response_errors(response)
        assign_attributes(response['body'])
        self.persisted = true
        clear_changes_information
      end

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
