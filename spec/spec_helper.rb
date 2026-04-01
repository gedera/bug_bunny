# frozen_string_literal: true

require 'bundler/setup'
require 'bug_bunny'
require 'connection_pool'
require 'socket'

# Carga variables de entorno desde .env si existe
env_file = File.join(__dir__, '..', '.env')
if File.exist?(env_file)
  File.readlines(env_file).each do |line|
    line = line.strip
    next if line.empty? || line.start_with?('#')

    key, value = line.split('=', 2)
    ENV[key.strip] = value.strip.delete("'\"") if key && value
  end
end

BugBunny.configure do |config|
  config.host     = ENV.fetch('RABBITMQ_HOST', 'localhost')
  config.username = ENV.fetch('RABBITMQ_USER', 'guest')
  config.password = ENV.fetch('RABBITMQ_PASS', 'guest')
  config.vhost    = '/'
  config.logger   = Logger.new($stdout).tap { |l| l.level = Logger::WARN }
  config.exchange_options = { durable: false, auto_delete: true }
  config.queue_options    = { exclusive: false, durable: false, auto_delete: true }
end

TEST_POOL ||= ConnectionPool.new(size: 5, timeout: 5) { BugBunny.create_connection }
BugBunny::Resource.connection_pool = TEST_POOL

# Routes globales para todos los specs
BugBunny.routes.draw do
  resources :ping
  resources :node
  resources :user
  get  'around',  to: 'around#index'
  get  'rescue',  to: 'rescue#index'
  get  'boom',    to: 'boom#index'
  get  'echo',    to: 'echo#index'
  post 'events',  to: 'event#create'
end

require 'support/integration_helper'
require 'support/bunny_mocks'

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.disable_monkey_patching!
  config.warnings = false
  config.order    = :random
  Kernel.srand config.seed

  # Skippea tests de integración si RabbitMQ no está disponible
  config.before(:each, :integration) do
    skip 'RabbitMQ no disponible' unless rabbitmq_available?
  end

  config.include_context 'integration helpers', :integration
end
