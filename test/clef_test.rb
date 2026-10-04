# frozen_string_literal: true

require "test_helper"
require "judge/clef"

class ClefTest < Minitest::Test
  ACCOUNT = "acct123"

  def setup
    @server = FakeJev.start(model: "clef", envelope: :cloudflare)
  end

  def teardown
    @server&.stop
    Judge.reset_config!
  end

  def config(adapter: :clef)
    Judge::Configuration.new.tap do |c|
      c.adapter = adapter
      c.api_key = "jev-key"
      c.cloudflare_api_token = "cf-token"
      c.cloudflare_account_id = ACCOUNT
      c.max_retries = 1
    end
  end

  def clef(cfg = config)
    Judge::Clef.new(config: cfg, sleeper: ->(_) {}, api_root: "http://#{@server.host}:#{@server.port}/client/v4")
  end

  def ask(client = clef, model: nil)
    client.call(state: "Checkout is down", questions: { urgent: Judge.noul("Is this urgent?") }, model: model)
  end

  def test_posts_the_jev_payload_to_the_account_scoped_model_url
    set = ask

    assert_equal "/client/v4/accounts/#{ACCOUNT}/ai/run/@cf/cloudflare/clef", @server.last_headers["path"]
    assert_equal "Bearer cf-token", @server.last_headers["authorization"]
    assert_equal "clef", @server.last_request["model"]
    assert_equal "Checkout is down", @server.last_request["state"]
    assert_equal "Is this urgent?", @server.last_request.dig("questions", "urgent", "instructions")
    assert_equal "clef", set.model
    assert_kind_of Float, set[:urgent].probability
  end

  def test_a_model_passed_per_call_picks_the_url
    ask(model: "clef-flash")

    assert @server.last_headers["path"].end_with?("/@cf/cloudflare/clef-flash")
    assert_equal "clef-flash", @server.last_request["model"]
  end

  def test_a_model_clef_does_not_serve_raises_before_any_request
    error = assert_raises(Judge::ConfigurationError) { ask(model: "jev-latest") }

    assert_includes error.message, "clef and clef-flash"
    assert_equal 0, @server.request_count
  end

  def test_a_missing_token_or_account_names_the_variable
    no_token = config.tap { |c| c.cloudflare_api_token = nil }
    no_account = config.tap { |c| c.cloudflare_account_id = nil }

    missing_token = assert_raises(Judge::ConfigurationError) { ask(clef(no_token)) }
    missing_account = assert_raises(Judge::ConfigurationError) { ask(clef(no_account)) }

    assert_includes missing_token.message, "CLOUDFLARE_API_TOKEN"
    assert_includes missing_account.message, "CLOUDFLARE_ACCOUNT_ID"
    assert_equal 0, @server.request_count
  end

  def test_cloudflare_errors_map_to_the_same_classes_with_their_message
    @server.fail_next(status: 401)
    auth = assert_raises(Judge::AuthenticationError) { ask }

    assert_includes auth.message, "injected failure"

    rejected = { "success" => false, "errors" => [{ "message" => "questions: Field required" }] }
    @server.fail_next(status: 422, body: JSON.generate(rejected))
    invalid = assert_raises(Judge::InvalidRequestError) { ask }

    assert_equal "Judge API returned 422: questions: Field required", invalid.message
  end

  def test_a_server_error_is_retried_like_jev
    @server.fail_next(status: 503)

    assert_equal "clef", ask.model
    assert_equal 2, @server.request_count
  end

  def test_a_200_without_success_is_an_invalid_response
    @server.fail_next(status: 200, body: JSON.generate("success" => false, "result" => nil,
                                                       "errors" => [{ "message" => "capacity" }]))

    assert_includes assert_raises(Judge::InvalidResponseError) { ask }.message, "capacity"
  end

  def test_the_adapter_registry_builds_clef
    assert_instance_of Judge::Clef, Judge::Adapter.build(:clef)
  end

  def test_inspect_never_shows_the_token
    refute_includes config.inspect, "cf-token"
    refute_includes clef.inspect, "cf-token"
  end
end

class ClefConfigurationTest < Minitest::Test
  VARS = %w[JUDGE_ADAPTER JEV_MODEL CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID].freeze

  def with_env(vars)
    previous = VARS.to_h { |k| [k, ENV.fetch(k, nil)] }
    VARS.each { |k| ENV.delete(k) }
    vars.each { |k, v| ENV[k] = v }
    yield Judge::Configuration.new
  ensure
    previous.each { |k, v| ENV[k] = v }
  end

  def test_the_jev_default_is_unchanged
    with_env({}) { |c| assert_equal "jev-latest", c.model }
  end

  def test_the_clef_adapter_defaults_to_the_clef_model
    with_env("JUDGE_ADAPTER" => "clef") { |c| assert_equal "clef", c.model }
  end

  def test_the_model_follows_an_adapter_switched_after_boot
    with_env({}) do |c|
      c.adapter = :clef

      assert_equal "clef", c.model
    end
  end

  def test_an_explicit_model_wins_over_the_adapter_default
    with_env("JUDGE_ADAPTER" => "clef", "JEV_MODEL" => "clef-flash") do |c|
      assert_equal "clef-flash", c.model
    end
    with_env("JUDGE_ADAPTER" => "clef") do |c|
      c.model = "clef-flash"

      assert_equal "clef-flash", c.model
    end
  end

  def test_cloudflare_credentials_come_from_the_environment
    with_env("CLOUDFLARE_API_TOKEN" => " cf-token ", "CLOUDFLARE_ACCOUNT_ID" => "acct") do |c|
      assert_equal "cf-token", c.cloudflare_api_token
      assert_equal "acct", c.cloudflare_account_id
    end
  end
end
