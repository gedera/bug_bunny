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

          if defined?(Rails)
            Rails.logger.info("Initializing #{options}")
          else
            puts "Initializing #{options}"
          end

          adapter_class = options[:adapter].constantize

          mode = options[:mode].to_sym || :sync

          queue_name = { sync: adapter_class::ROUTING_KEY_SYNC_REQUEST, async: adapter_class::ROUTING_KEY_ASYNC_REQUEST }[mode]

          loop do
            begin
              adapter = adapter_class.new

              queue = adapter.build_queue(queue_name, adapter_class::QUEUES_PROPS[queue_name])

              if mode == :async
                adapter.build_queue(
                  adapter_class::ROUTING_KEY_ASYNC_RESPONSE,
                  adapter_class::QUEUES_PROPS[adapter_class::ROUTING_KEY_ASYNC_RESPONSE]
                )
              end
            rescue ::BugBunny::Exception::ComunicationRabbitError => e
              if defined?(Rails)
                Rails.logger.error(e)
              else
                puts e.message
              end

              (adapter ||= nil).try(:close_connection!) # ensure the adapter is close
              sleep 5
              retry
            end

            adapter.consume!(queue) do |message|
              begin
                if options[:session]
                  ::Session.request_id = message.correlation_id rescue nil
                  ::Session.tags_context ||= {}

                  ::Session.extra_context ||= {}
                  ::Session.extra_context[:message] = message.body
                  # para que cada servicio setee valores de session segun sus necesidades
                  try(:set_sentry_context, message)
                end

                response = nil

                Timeout.timeout(5.minutes) do
                  if defined?(Rails)
                    Rails.logger.debug("Msg received: action: #{message.service_action}, msg: #{message.body}")
                  else
                    puts "Msg received: action: #{message.service_action}, msg: #{message.body}"
                  end
                  response = "#{options[:adapter]}Controller".constantize.exec_action(message)
                end
              rescue Timeout::Error => e
                puts("[OLT_VSOL_SERVICE][TIMEOUT][CONSUMER] #{e.to_s})")
                @exception = e
              rescue StandardError => e
                adapter.check_pg_exception!(e)
                if defined?(Rails)
                  Rails.logger.error(e)
                else
                  puts e.message
                end
                @exception = e
              end

              if message.reply_to
                Session.reply_to_queue = message.reply_to if options[:session]
                begin
                  msg = message.build_message
                  if @exception
                    msg.body = (response&.key?(:body)) ? response[:body] : { id: message.body[:id] }
                    msg.exception = @exception
                    @exception = nil
                  else
                    msg.body = response[:body]
                    msg.status = response[:status] if response.key?(:status)
                  end

                  queue = adapter.build_queue(message.reply_to, initialize: false)
                  adapter.publish!(msg, queue)
                rescue => e
                  if defined?(Rails)
                    Rails.logger.error(e)
                  else
                    puts e.message
                  end
                end
              end
              Session.clean! if options[:session]
            end
            sleep 5
          end
        end
      end
    end
  end
end
