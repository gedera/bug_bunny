# frozen_string_literal: true

require 'bunny'
require_relative "bug_bunny/version"
require_relative "bug_bunny/adapter"
require_relative "bug_bunny/controller"
require_relative "bug_bunny/exception"
require_relative "bug_bunny/message"
require_relative "bug_bunny/queue"
require_relative "bug_bunny/rabbit"
require_relative "bug_bunny/response"
require_relative "bug_bunny/security"
require_relative "bug_bunny/helpers"

if defined? ::Rails::Railtie
  ## Rails only files
  require 'bug_bunny/railtie'
end

module BugBunny
end
