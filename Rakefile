# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'rubocop/rake_task'
require 'rspec/core/rake_task'

# 1. Configurar tarea de RuboCop
RuboCop::RakeTask.new

# 2. Configurar tarea de RSpec
RSpec::Core::RakeTask.new(:spec) do |t|
  # Patrón por defecto para encontrar tests
  t.pattern = Dir.glob('spec/**/*_spec.rb')
end

# 3. Tarea por defecto (corre tests y linter)
task default: %i[spec rubocop]
