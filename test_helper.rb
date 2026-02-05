# test_helper.rb
require_relative 'lib/bug_bunny'

# Forzar flush de logs
$stdout.sync = true

BugBunny.configure do |config|
  config.host = 'localhost'
  config.username = 'wisproMQ'
  config.password = 'wisproMQ'
  config.vhost = 'sync.devel'
  config.logger = Logger.new(STDOUT)
  config.logger.level = Logger::WARN # Menos ruido, solo errores importantes
  config.rpc_timeout = 5
end

# Pool compartido
TEST_POOL = ConnectionPool.new(size: 5, timeout: 5) do
  BugBunny.create_connection
end
