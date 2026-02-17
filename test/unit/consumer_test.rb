# frozen_string_literal: true

require_relative '../test_helper'

class ConsumerTest < Minitest::Test
  def setup
    @connection = mock('Bunny::Session')
    @channel = mock('Bunny::Channel')

    # Stubs para que Consumer.new no falle
    @connection.stubs(:open?).returns(true)
    @connection.stubs(:create_channel).returns(@channel)
    @connection.stubs(:close)

    # Stubs para Session y Channel
    @channel.stubs(:confirm_select)
    @channel.stubs(:prefetch)
    @channel.stubs(:open?).returns(true)
    @channel.stubs(:close)

    @consumer = BugBunny::Consumer.new(@connection)
  end

  def test_router_dispatch
    # Probamos la lógica interna del Router (método privado router_dispatch)

    # Caso 1: POST /users -> Create
    route_post = @consumer.send(:router_dispatch, 'POST', 'users')
    assert_equal 'users', route_post[:controller]
    assert_equal 'create', route_post[:action]

    # Caso 2: GET /users/123 -> Show
    route_show = @consumer.send(:router_dispatch, 'GET', 'users/123')
    assert_equal 'users', route_show[:controller]
    assert_equal 'show', route_show[:action]
    assert_equal '123', route_show[:id]

    # Caso 3: Custom Action (POST /users/1/promote)
    route_custom = @consumer.send(:router_dispatch, 'POST', 'users/1/promote')
    assert_equal 'users', route_custom[:controller]
    assert_equal 'promote', route_custom[:action]
    assert_equal '1', route_custom[:id]
  end
end
