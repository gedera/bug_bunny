# frozen_string_literal: true

require 'rails/generators'

module BugBunny
  module Generators
    class InstallGenerator < Rails::Generators::Base
      # Indica dónde buscar las plantillas (la carpeta 'templates' hermana de este archivo)
      source_root File.expand_path('templates', __dir__)

      desc "Instala la configuración inicial de BugBunny"

      def create_initializer
        # Copia el archivo plantilla al destino final
        template 'initializer.rb', 'config/initializers/bug_bunny.rb'
      end

      def create_directories
        # Crea la estructura de carpetas necesaria para los controladores
        empty_directory "app/rabbit/controllers"

        # Crea un archivo .keep para que git no ignore la carpeta vacía
        create_file "app/rabbit/controllers/.keep", ""
        puts "🐰 BugBunny structure created successfully!"
      end
    end
  end
end
