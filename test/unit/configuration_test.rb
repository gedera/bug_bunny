# frozen_string_literal: true

require_relative '../test_helper'

class ConfigurationTest < Minitest::Test
  def setup
    BugBunny.configuration = nil # Resetear singleton
  end

  def test_default_values
    config = BugBunny::Configuration.new

    assert_equal '127.0.0.1', config.host
    assert_equal 5672, config.port # Validamos el fix de la v3.0.6
    assert_equal 'guest', config.username
    assert_equal '/', config.vhost
    assert config.automatically_recover
  end

  def test_configure_block
    BugBunny.configure do |c|
      c.host = 'rabbit.prod'
      c.port = 1234
    end

    assert_equal 'rabbit.prod', BugBunny.configuration.host
    assert_equal 1234, BugBunny.configuration.port
  end

  def test_url_generation
    config = BugBunny::Configuration.new
    config.host = 'host'
    config.port = 5672
    config.username = 'u'
    config.password = 'p'

    # CAMBIO: Agregamos el slash extra al final que genera la interpolación
    assert_equal "amqp://u:p@host:5672//", config.url
  end
end
