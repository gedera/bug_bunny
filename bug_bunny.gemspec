# frozen_string_literal: true

require_relative 'lib/bug_bunny/version'

Gem::Specification.new do |spec|
  spec.name = 'bug_bunny'
  spec.version = BugBunny::VERSION
  spec.authors = ['gabix']
  spec.email = ['gab.edera@gmail.com']

  spec.summary = 'Gem for sync and async comunication via rabbit bunny.'
  spec.description = 'BugBunny is a lightweight RPC framework for Ruby on Rails over RabbitMQ. ' \
                     'It simulates a RESTful architecture with an intelligent router, ' \
                     'Active Record-like resources, and middleware support.'
  spec.homepage = 'https://github.com/gedera/bug_bunny'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 2.6.0'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/gedera/bug_bunny'
  spec.metadata['changelog_uri'] = 'https://github.com/gedera/bug_bunny/blob/main/CHANGELOG.md'

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{\A(?:test|spec|features)/}) }
  end
  spec.bindir = 'exe'
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  # Dependencies sorted alphabetically
  spec.add_dependency 'activemodel', '>= 6.1'
  spec.add_dependency 'activesupport', '>= 6.1'
  spec.add_dependency 'bunny', '~> 2.24'
  spec.add_dependency 'concurrent-ruby', '~> 1.3'
  spec.add_dependency 'connection_pool', '>= 2.4'
  spec.add_dependency 'json', '>= 2.0'
  spec.add_dependency 'ostruct'
  spec.add_dependency 'rack', '>= 2.0'

  spec.add_development_dependency 'bundler', '>= 2.0'
  spec.add_development_dependency 'rake', '~> 13.0'
  spec.add_development_dependency 'rspec', '~> 3.0'
  spec.add_development_dependency 'yard', '~> 0.9'
end
