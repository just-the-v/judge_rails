# frozen_string_literal: true

require "test_helper"

class ClientPoolTest < Minitest::Test
  def setup
    @server = FakeJev.start
    Thread.current[Judge::Client::CONNECTIONS_KEY] = nil
  end

  def teardown
    @server&.stop
    Thread.current[Judge::Client::CONNECTIONS_KEY] = nil
    Judge.reset_config!
  end

  def config(timeout: 10.0, open_timeout: 5.0, base_url: @server.url)
    Judge::Configuration.new.tap do |c|
      c.api_key = "test-key"
      c.base_url = base_url
      c.timeout = timeout
      c.open_timeout = open_timeout
    end
  end

  def ask(client)
    client.call(state: "hello", questions: { a: Judge.noul("urgent?") })
  end

  def pool
    Thread.current[Judge::Client::CONNECTIONS_KEY] || {}
  end

  def test_clients_with_different_timeouts_do_not_share_a_connection
    app = Judge::Client.new(config: config(timeout: 30.0))
    visitor = Judge::Client.new(config: config(timeout: 2.0))
    ask(app)
    ask(visitor)

    assert_equal 2, pool.size
    assert_equal [2.0, 30.0], pool.values.map(&:read_timeout).sort
  end

  def test_a_client_reuses_its_own_connection
    client = Judge::Client.new(config: config)
    ask(client)
    first = pool.values.first
    ask(client)

    assert_equal 1, pool.size
    assert_same first, pool.values.first
  end

  def test_a_visitor_client_failing_does_not_close_the_shared_connection
    app = Judge::Client.new(config: config(timeout: 30.0))
    ask(app)
    app_connection = pool.values.first

    visitor = Judge::Client.new(config: config(timeout: 2.0))
    @server.always_fail(status: 503)
    assert_raises(Judge::ServerError) { ask(visitor) }
    @server.clear_failures!

    assert_predicate app_connection, :started?
    ask(app)

    assert_same app_connection, pool[[@server.url, 5.0, 30.0]]
  end

  def test_changing_base_url_on_a_live_config_is_honoured
    other = FakeJev.start
    cfg = config
    client = Judge::Client.new(config: cfg)
    ask(client)

    cfg.base_url = other.url
    ask(client)

    assert_equal 1, other.request_count
    assert_equal 1, @server.request_count
  ensure
    other&.stop
  end
end

class ConfigurationKeyTest < Minitest::Test
  def with_env(vars)
    previous = vars.to_h { |k, _| [k, ENV.fetch(k, nil)] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    previous.each { |k, v| ENV[k] = v }
  end

  def test_an_empty_jev_api_key_falls_back_to_the_typesafe_variable
    with_env("JEV_API_KEY" => "", "TYPESAFE_API_KEY" => "from-typesafe") do
      assert_equal "from-typesafe", Judge::Configuration.new.api_key
    end
  end

  def test_a_set_jev_api_key_wins
    with_env("JEV_API_KEY" => "from-jev", "TYPESAFE_API_KEY" => "from-typesafe") do
      assert_equal "from-jev", Judge::Configuration.new.api_key
    end
  end

  def test_both_empty_leaves_the_key_nil_and_raises_on_demand
    with_env("JEV_API_KEY" => "", "TYPESAFE_API_KEY" => "  ") do
      config = Judge::Configuration.new

      assert_nil config.api_key
      assert_raises(Judge::ConfigurationError) { config.api_key! }
    end
  end

  def test_a_whitespace_key_assigned_directly_is_still_rejected
    config = Judge::Configuration.new
    config.api_key = "   "

    assert_raises(Judge::ConfigurationError) { config.api_key! }
  end
end
