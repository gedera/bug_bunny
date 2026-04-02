# frozen_string_literal: true

require 'rails/generators'

module BugBunny
  module Generators
    # Generador de instalación estándar de Rails para BugBunny.
    #
    # Este generador se encarga de realizar el "scaffolding" inicial necesario para
    # integrar la gema en una aplicación Rails existente.
    #
    # Acciones principales:
    # 1. Crea el archivo de configuración (Initializer).
    # 2. Establece la estructura de directorios para los controladores AMQP.
    #
    # @example Ejecución desde la terminal
    #   rails generate bug_bunny:install
    class InstallGenerator < Rails::Generators::Base
      # Define la raíz de los recursos para buscar las plantillas (templates).
      # @api private
      source_root File.expand_path('templates', __dir__)

      desc 'Instala la configuración inicial de BugBunny y crea la estructura de directorios.'

      # Genera el archivo de configuración inicial.
      # Copia la plantilla `initializer.rb` a `config/initializers/bug_bunny.rb` en la app destino.
      #
      # @return [void]
      def create_initializer
        template 'initializer.rb', 'config/initializers/bug_bunny.rb'
      end

      # Crea la estructura de carpetas necesaria para el patrón MVC de BugBunny.
      #
      # Genera:
      # * `app/bug_bunny/controllers/`: Directorio donde vivirán los controladores de consumidores.
      # * `.keep`: Archivo marcador para asegurar que Git rastree la carpeta aunque esté vacía.
      #
      # @return [void]
      def create_directories
        empty_directory 'app/bug_bunny/controllers'
        create_file 'app/bug_bunny/controllers/.keep', ''
      end

      # Escribe el bloque inicial de BugBunny en CLAUDE.md del proyecto consumidor.
      #
      # Si CLAUDE.md no existe, crea uno mínimo con la sección correspondiente.
      # Si ya existe, agrega la sección `## Gemas internas` con el bloque de bug_bunny.
      # En ambos casos, el rake task `bug_bunny:sync` se encarga de las actualizaciones futuras.
      #
      # @return [void]
      def update_claude_md
        spec = Gem::Specification.find_by_name('bug_bunny')
        version = spec.version.to_s
        docs_path = File.join(spec.gem_dir, 'docs', 'ai')

        block = <<~BLOCK
          ## Gemas internas

          ### bug_bunny
          - **Version:** #{version}
          - **Docs:** #{docs_path}
          - **Updated:** #{Time.now.strftime('%Y-%m-%d')}
        BLOCK

        claude_md = File.join(destination_root, 'CLAUDE.md')

        if File.exist?(claude_md)
          content = File.read(claude_md)
          if content.include?('### bug_bunny')
            say_status :skip, 'CLAUDE.md already has a bug_bunny block — run `rake bug_bunny:sync` to update'
          elsif content.include?('## Gemas internas')
            inject_into_file 'CLAUDE.md', "\n#{block.lines.drop(2).join}", after: "## Gemas internas\n"
            say_status :update, 'Added bug_bunny block to existing ## Gemas internas section in CLAUDE.md'
          else
            append_to_file 'CLAUDE.md', "\n#{block}"
            say_status :update, 'Added ## Gemas internas section to CLAUDE.md'
          end
        else
          create_file 'CLAUDE.md', "# #{Rails.application.class.module_parent_name}\n\n#{block}"
          say_status :create, 'CLAUDE.md created with bug_bunny block'
        end

        say '  Add `bundle exec rake bug_bunny:sync` to bin/setup to keep this block up to date.'
      end
    end
  end
end
