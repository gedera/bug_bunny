# frozen_string_literal: true

require 'bunny'
require_relative 'bug_bunny/version'
require_relative 'bug_bunny/config'
require_relative 'bug_bunny/controller'
require_relative 'bug_bunny/publisher'
require_relative 'bug_bunny/exception'
require_relative 'bug_bunny/rabbit'
require_relative 'bug_bunny/resource'

module BugBunny
  class << self
    # Aquí guardaremos la instancia de la configuración
    def configuration
      @configuration ||= BugBunny::Config.new
    end

    # Este es el método que usaremos para configurar.
    # Recibe un bloque de código y le pasa el objeto de configuración.
    def configure
      yield(configuration) if block_given?
    end
  end
end
