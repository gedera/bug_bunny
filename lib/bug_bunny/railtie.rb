# lib/bug_bunny/railtie.rb
require 'rails'

module BugBunny
  class Railtie < ::Rails::Railtie
    # 1. Autoload
    initializer "bug_bunny.add_autoload_paths" do |app|
      rabbit_path = File.join(app.root, 'app', 'rabbit')
      if Dir.exist?(rabbit_path)
        app.config.autoload_paths << rabbit_path
        app.config.eager_load_paths << rabbit_path
      end
    end

    # 2. Hook Puma
    config.after_initialize do
      if defined?(Puma)
        Puma.events.on_worker_boot do
          BugBunny::Rabbit.disconnect
        end
      end
    end

    # 3. Hook Spring
    if defined?(Spring)
      Spring.after_fork do
        BugBunny::Rabbit.disconnect
      end
    end
  end
end
