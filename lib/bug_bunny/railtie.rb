# frozen_string_literal: true

# lib/bug_bunny/railtie.rb
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
    #
    # Agrega el directorio `app/rabbit` a los paths de carga automática.
    # Esto permite que Rails encuentre automáticamente los controladores definidos por el usuario
    # (ej: `Rabbit::Controllers::Users`) sin necesidad de `require` manuales.
    initializer 'bug_bunny.add_autoload_paths' do |app|
      rabbit_path = File.join(app.root, 'app', 'rabbit')
      if Dir.exist?(rabbit_path)
        app.config.autoload_paths << rabbit_path
        app.config.eager_load_paths << rabbit_path
      end
    end

    # 2. Hook de Puma (Servidor Web)
    #
    # Detecta cuando Puma arranca un nuevo "worker" en modo clúster.
    # Es vital cerrar la conexión heredada del proceso padre (Master) antes de que
    # el hijo empiece a trabajar, para evitar compartir el mismo socket TCP.
    #
    # La nueva conexión se creará perezosamente (Lazy) cuando el worker la necesite.
    config.after_initialize do
      if defined?(Puma)
        Puma.events.on_worker_boot do
          BugBunny::Rabbit.disconnect
        end
      end
    end

    # 3. Hook de Spring (Preloader)
    #
    # Spring mantiene una instancia de la aplicación en memoria y hace `fork` para
    # ejecutar comandos (rails c, rspec, etc) rápidamente.
    #
    # Al igual que con Puma, debemos desconectar la conexión al RabbitMQ justo después
    # del fork para asegurar que el nuevo proceso tenga su propio socket limpio.
    if defined?(Spring)
      Spring.after_fork do
        BugBunny::Rabbit.disconnect
      end
    end
  end
end
