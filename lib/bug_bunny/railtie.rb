# frozen_string_literal: true

require 'rails'

module BugBunny
  # Integración automática de BugBunny con el ciclo de vida de Ruby on Rails.
  #
  # Esta clase es responsable de:
  # 1. Registrar la carpeta `app/rabbit` en el autoloader de Rails (Zeitwerk).
  # 2. Gestionar la seguridad de las conexiones durante el "forking" de procesos (Puma/Spring).
  #
  # @see https://guides.rubyonrails.org/engines.html#railtie
  class Railtie < ::Rails::Railtie
    # 1. Configuración de Autoload
    initializer 'bug_bunny.add_autoload_paths' do |app|
      rabbit_path = File.join(app.root, 'app', 'rabbit')
      if Dir.exist?(rabbit_path)
        app.config.autoload_paths << rabbit_path
        app.config.eager_load_paths << rabbit_path
      end
    end

    # 2. Gestión de Forks (Puma / Spring / otros)
    #
    # Es vital cerrar la conexión heredada del proceso padre (Master) antes de que
    # el hijo empiece a trabajar, para evitar compartir el mismo socket TCP.
    config.after_initialize do
      # Estrategia 1: Rails 7.1+ ForkTracker (La forma estándar moderna)
      if defined?(ActiveSupport::ForkTracker)
        ActiveSupport::ForkTracker.after_fork { BugBunny.disconnect }
      end

      # Estrategia 2: Hook específico de Puma (Legacy)
      # Solo intentamos usarlo si la API 'events' está disponible (Puma < 5).
      if defined?(Puma) && Puma.respond_to?(:events)
        Puma.events.on_worker_boot do
          BugBunny.disconnect
        end
      end
    end

    # 3. Hook de Spring (Preloader)
    if defined?(Spring)
      Spring.after_fork do
        BugBunny.disconnect
      end
    end
  end
end
