# lib/bug_bunny/railtie.rb
require 'rails'

module BugBunny
  class Railtie < ::Rails::Railtie
    # 1. Configuración de Autoload (lo que ya tenías)
    initializer "bug_bunny.add_autoload_paths" do |app|
      rabbit_path = File.join(app.root, 'app', 'rabbit')
      if Dir.exist?(rabbit_path)
        app.config.autoload_paths << rabbit_path
        app.config.eager_load_paths << rabbit_path
      end
    end

    # 2. Hook para Puma (Servidor Web de Producción)
    config.after_initialize do
      if defined?(Puma)
        Puma.events.on_worker_boot do
          # Cuando Puma crea un nuevo worker, desconectamos la conexión heredada
          # para que la primera llamada en este nuevo proceso cree una limpia.
          BugBunny::Rabbit.disconnect
        end
      end
    end

    # 3. Hook para Spring (Entorno de Desarrollo)
    if defined?(Spring)
      Spring.after_fork do
        # Igual que Puma, pero para desarrollo rápido
        BugBunny::Rabbit.disconnect
      end
    end
  end
end
