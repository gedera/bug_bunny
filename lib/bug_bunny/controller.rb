module BugBunny
  class Controller
    def self.health_check(_message)
      { status: :success, body: {} }
    end

    def self.exec_action(message)
      send(message.service_action, message)
    end

    def self.method_missing(name, message, *args, &block)
      Session.message = message
      message.build_message(reply_to: message.reply_to).server_no_action!
    end
  end
end
