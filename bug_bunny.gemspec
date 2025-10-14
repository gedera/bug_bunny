# frozen_string_literal: true

require_relative "lib/bug_bunny/version"

Gem::Specification.new do |spec|
  spec.name = "bug_bunny"
  spec.version = BugBunny::VERSION
  spec.authors = ["gabix"]
  spec.email = ["gab.edera@gmail.com"]

  spec.summary = "Gem for sync and async comunication via rabbit bunny."
  spec.description = "Gem for sync and async comunication via rabbit bunny."
  spec.homepage = "https://github.com/gedera/bug_bunny"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 2.6.0"

  # spec.metadata["allowed_push_host"] = "TODO: Set to your gem server 'https://example.com'"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/gedera/bug_bunny"
  spec.metadata["changelog_uri"] = "https://github.com/gedera/bug_bunny/blob/main/CHANGELOG.md"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
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

  # Uncomment to register a new dependency of your gem
  # spec.add_dependency "example-gem", "~> 1.0"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
  spec.add_dependency "bunny", "~> 2.24"
end
