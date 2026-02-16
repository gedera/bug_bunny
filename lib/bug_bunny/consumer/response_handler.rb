# frozen_string_literal: true

require 'json'

module BugBunny
  class Consumer
    # Módulo encargado de enviar respuestas, rechazos y manejar errores fatales.
    module ResponseHandler
      private

      def reply_if_needed(payload, headers)
        return unless headers[:reply_to]

        reply(payload, headers[:reply_to], headers[:correlation_id])
      end

      def reply(payload, reply_to, correlation_id)
        session.channel.default_exchange.publish(
          payload.to_json,
          routing_key: reply_to,
          correlation_id: correlation_id,
          content_type: 'application/json'
        )
      end

      def handle_routing_error(delivery_info, properties, error)
        BugBunny.configuration.logger.error("[Consumer] Routing Error: #{error.message}")
        handle_fatal_error(properties, 501, 'Routing Error', error.message)
        session.channel.reject(delivery_info.delivery_tag, false)
      end

      def handle_server_error(delivery_info, properties, error)
        BugBunny.configuration.logger.error("[Consumer] Execution Error: #{error.message}")
        handle_fatal_error(properties, 500, 'Internal Server Error', error.message)
        session.channel.reject(delivery_info.delivery_tag, false)
      end

      def handle_fatal_error(properties, status, error_title, detail)
        return unless properties.reply_to

        error_payload = { status: status, body: { error: error_title, detail: detail } }
        reply(error_payload, properties.reply_to, properties.correlation_id)
      end

      def reject_message(delivery_info, reason)
        BugBunny.configuration.logger.error("[Consumer] #{reason}. Message rejected.")
        session.channel.reject(delivery_info.delivery_tag, false)
      end
    end
  end
end
