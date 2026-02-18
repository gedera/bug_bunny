# frozen_string_literal: true

require_relative "lib/bug_bunny/version"

Gem::Specification.new do |spec|
  spec.name = "bug_bunny"
  spec.version = BugBunny::VERSION
  spec.authors = ["gabix"]
  spec.email = ["gab.edera@gmail.com"]

  spec.summary = "Gem for sync and async comunication via rabbit bunny."
  # CORRECCIÓN: Descripción más detallada para evitar warning de identidad
  spec.description = "BugBunny is a lightweight RPC framework for Ruby on Rails over RabbitMQ. It simulates a RESTful architecture with an intelligent router, Active Record-like resources, and middleware support."

  spec.homepage = "https://github.com/gedera/bug_bunny"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 2.6.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/gedera/bug_bunny"
  spec.metadata["changelog_uri"] = "https://github.com/gedera/bug_bunny/blob/main/CHANGELOG.md"

  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore .github/ .rubocop.yml])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # === DEPENDENCIAS DE RUNTIME ===
  spec.add_dependency "bunny", "~> 2.24"
  spec.add_dependency "connection_pool", ">= 2.4"
  spec.add_dependency "concurrent-ruby", "~> 1.3"

  # Mantenemos >= para compatibilidad amplia con Rails, aunque RubyGems avise.
  # Si quieres ser estricto usa "~> 7.0"
  spec.add_dependency "activemodel", ">= 6.1"
  spec.add_dependency "activesupport", ">= 6.1"
  spec.add_dependency "rack", ">= 2.0"

  # CORRECCIÓN: Agregamos versiones mínimas o rangos para evitar warnings
  spec.add_dependency "json", ">= 2.0"
  spec.add_dependency "ostruct"

  # === DEPENDENCIAS DE DESARROLLO (Acotadas) ===
  spec.add_development_dependency "bundler", ">= 2.0"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.0"
  spec.add_development_dependency "yard", "~> 0.9"

  spec.add_development_dependency 'minitest', '~> 5.0'
  spec.add_development_dependency 'mocha', '~> 2.0'
  spec.add_development_dependency "minitest-reporters", "~> 1.6"
end
