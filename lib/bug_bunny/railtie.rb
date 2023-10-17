module BugBunny
  class Railtie < Rails::Railtie
    rake_tasks do
      namespace :bug_bunny do |args|
        ARGV.shift

        desc 'Bug Bunny consumer'
        # environment is required to have access to Rails models
        task consumer: :environment do
          options = {}

          o = OptionParser.new

          o.banner = "Usage: rake bug_bunny:consumer [options]"
          o.on("-a ADAPTER", "--adapter ADAPTER") { |adapter| options[:adapter] = adapter }
          o.on("-s", "--session") { options[:session] = true }
          o.on("-m MODE", "--mode MODE", "Sync or Async mode. values [:sync, :async]") { |mode| options[:mode] = mode }
          o.on("-h", "--help", 'HELP ME!!! HELPE ME!!!') { puts o }

          args = o.order!(ARGV) {}

          o.parse!(args)

          Rails.logger.info("[BUG_BUNNY][CONSUMER] Initializing #{options}")

          adapter_class = options[:adapter].constantize

          mode = options[:mode].to_sym || :sync

          queue_name = { sync: adapter_class::ROUTING_KEY_SYNC_REQUEST, async: adapter_class::ROUTING_KEY_ASYNC_REQUEST }[mode]

          begin
            adapter = adapter_class.new

            queue = adapter.build_queue(queue_name, adapter_class::QUEUES_PROPS[queue_name])

            msg = "[BUG_BUNNY][CONSUMER] Building queue #{queue_name} => #{adapter_class::QUEUES_PROPS[queue_name]}"

            Rails.logger.info(msg)

            if mode == :async
              msg = "[BUG_BUNNY][CONSUMER] Building queue async response #{adapter_class::ROUTING_KEY_ASYNC_RESPONSE} => #{adapter_class::QUEUES_PROPS[adapter_class::ROUTING_KEY_ASYNC_RESPONSE]}"
              Rails.logger.debug(msg)
              adapter.build_queue(adapter_class::ROUTING_KEY_ASYNC_RESPONSE, adapter_class::QUEUES_PROPS[adapter_class::ROUTING_KEY_ASYNC_RESPONSE])
            end
          rescue StandardError => e
            Rails.logger.error(e)

            exit 0
          end

          adapter.consume!(queue) do |message|
            begin
              if options[:session]
                ::Session.request_id = message.correlation_id rescue nil
                ::Session.tags_context ||= {}

                ::Session.extra_context ||= {}
                ::Session.extra_context[:message] = message.body
              end

              response = nil

              Rails.logger.debug("[BUG_BUNNY][CONSUMER][MSG_RECEIVED] ACTION: #{message.service_action}, MESSAGE: #{message.body}")
              response = "#{options[:adapter]}Controller".constantize.exec_action(message)
            rescue StandardError => e
              Rails.logger.debug("[BUG_BUNNY][CONSUMER][MSG_RECEIVED] ENTRO AL RESCUE DEL CONSUMER")
              Rails.logger.error(e)
              @exception = e
            end

            if message.reply_to
              Session.reply_to_queue = message.reply_to if options[:session]
              retries = 3

              begin
                msg = message.build_message

                if @exception
                  msg.body = response&.key?(:body) ? response[:body] : { id: message.body[:id] }
                  msg.exception = @exception
                else
                  msg.body = response[:body]
                  msg.status = response[:status] if response.key?(:status)
                end

                queue = adapter.build_queue(message.reply_to, initialize: false)

                Rails.logger.debug("[BUG_BUNNY][CONSUMER] Reply to #{message.reply_to} with #{msg}")

                adapter.publish!(msg, queue)
              rescue StandardError => e
                if e.instance_of?(::BugBunny::Exception::ComunicationRabbitError) && retries.positive?
                  retries -= 1

                  retry
                end

                Rails.logger.debug("[BUG_BUNNY][CONSUMER][MSG_RECEIVED] ENTRO AL RESCUE DEL REPLY TO")
                Rails.logger.error(e)
                Rails.logger.debug("[BUG_BUNNY][CONSUMER][MSG_RECEIVED] EXIT")

                exit 0
              end
            end
            Session.clean! if options[:session]
          end
        rescue StandardError => e
          Rails.logger.debug("[BUG_BUNNY][CONSUMER][MSG_RECEIVED] ENTRO EN EL RESCUE GENERAL")
          Rails.logger.error(e)
          Rails.logger.debug("[BUG_BUNNY][CONSUMER][MSG_RECEIVED] EXIT")

          exit 0
        end
      end
    end
  end
end
