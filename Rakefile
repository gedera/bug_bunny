require 'bundler/gem_tasks'
require 'rake/testtask'
require 'rspec/core/rake_task'

RSpec::Core::RakeTask.new(:spec) do |t|
  t.rspec_opts = '--require spec_helper'
end

RSpec::Core::RakeTask.new('spec:unit') do |t|
  t.pattern  = 'spec/unit/**/*_spec.rb'
  t.rspec_opts = '--require spec_helper'
end

RSpec::Core::RakeTask.new('spec:integration') do |t|
  t.pattern  = 'spec/integration/**/*_spec.rb'
  t.rspec_opts = '--require spec_helper'
end

# Mantiene la tarea :test apuntando a los tests de integración legacy de Minitest
Rake::TestTask.new(:test) do |t|
  t.libs << 'test'
  t.libs << 'lib'
  t.test_files = FileList['test/**/*_test.rb']
  t.verbose    = true
  t.warning    = false
end

task default: :spec
