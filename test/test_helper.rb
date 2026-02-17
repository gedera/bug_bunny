# frozen_string_literal: true
require 'bundler/setup'

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'bug_bunny'

require 'minitest/autorun'
require 'mocha/minitest'
require 'logger'

BugBunny.configure do |config|
  config.logger = Logger.new(nil)
  config.bunny_logger = Logger.new(nil)
end

module TestHelper
  def self.rabbitmq_available?
    socket = TCPSocket.new('localhost', 5672)
    socket.close
    true
  rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT
    false
  end
end
