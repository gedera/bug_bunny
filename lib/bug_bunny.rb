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

require 'active_support/all'

if defined? ::Rails::Railtie
  ## Rails only files
  require 'bug_bunny/railtie'
end

module BugBunny
  include ActiveSupport::Configurable

  configure do |config|
    config.service_name = :bug_bunny
    config.default_queue = :bug_bunny
    config.default_props = { durable: true, auto_delete: false, exclusive: false }
    config.timeout = 1.minute
    config.retry = 3
    config.logger = Logger.new(STDOUT)
  end
end
