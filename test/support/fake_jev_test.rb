# frozen_string_literal: true

require "test_helper"
require "net/http"
require_relative "fake_jev"
require_relative "canned"

class FakeJevTest < Minitest::Test
  def setup
    @server = FakeJev.start
  end

  def teardown
    @server&.stop
  end

  def post(body = Canned.request_json, token: "sk-test", server: @server)
    uri = URI(server.url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.read_timeout = 5
    request = Net::HTTP::Post.new(uri.path, "Content-Type" => "application/json")
    request["Authorization"] = "Bearer #{token}" if token
    request.body = body
    http.start { |conn| conn.request(request) }
  end

  def test_synthesises_an_answer_per_question
    body = JSON.parse(post.body)

    assert_equal %w[urgent topic anger], body["answers"].keys
    assert_equal "noul", body.dig("answers", "urgent", "type")
    assert_equal "choice", body.dig("answers", "topic", "type")
    assert_equal "score", body.dig("answers", "anger", "type")
    assert_operator body.dig("usage", "input_tokens"), :positive?
  end

  def test_answers_are_byte_identical_for_identical_input
    assert_equal post.body, post.body
  end

  def test_different_state_changes_the_answers
    other = JSON.generate(Canned::REQUEST.merge("state" => "All good, thanks for the quick fix!"))

    refute_equal post.body, post(other).body
  end

  def test_choice_probabilities_sum_to_one
    answer = JSON.parse(post.body).dig("answers", "topic")

    assert_in_delta 1.0, answer["probabilities"].values.sum, 1e-9
    assert_equal answer["probabilities"].max_by { |_, p| p }.first, answer["choice"]
    assert_includes 0.0..1.0, answer["confidence"]
  end

  def test_score_legend_matches_criteria_and_score_follows_the_distribution
    answer = JSON.parse(post.body).dig("answers", "anger")

    assert_equal({ "0" => "Calm", "1" => "Frustrated", "2" => "Very angry" }, answer["legend"])
    assert_in_delta 1.0, answer["probabilities"].values.sum, 1e-9
    expected = answer["probabilities"].sum { |level, p| level.to_i * p }

    assert_in_delta expected, answer["score"], 0.01
    assert_includes answer["legend"].keys, answer["score"].round.to_s
  end

  def test_synthesised_answers_are_coercible_into_results
    body = JSON.parse(post.body)
    results = Judge::ResultSet.from_response(body, questions: Canned.questions)

    assert_equal 3, results.size
    assert_kind_of Float, results[:urgent].value
    assert_includes %w[billing technical sales], results[:topic].value
    assert_includes ["Calm", "Frustrated", "Very angry"], results[:anger].label
  end

  def test_global_override_replaces_the_synthesised_answer
    @server.answer(:urgent, { "type" => "noul", "noul" => 0.9 })

    assert_equal({ "type" => "noul", "noul" => 0.9 }, JSON.parse(post.body).dig("answers", "urgent"))
  end

  def test_scoped_override_wins_over_global_and_only_on_matching_state
    @server.answer(:urgent, { "type" => "noul", "noul" => 0.1 })
    @server.answer_for("invoice", :urgent, { "type" => "noul", "noul" => 0.99 })

    assert_in_delta(0.99, JSON.parse(post.body).dig("answers", "urgent", "noul"))

    other = JSON.generate(Canned::REQUEST.merge("state" => "nothing to see"))

    assert_in_delta(0.1, JSON.parse(post(other).body).dig("answers", "urgent", "noul"))
  end

  def test_fail_next_then_recovery
    @server.fail_next(2, status: 500)

    assert_equal "500", post.code
    assert_equal "server_error", JSON.parse(post.body).dig("error", "type")
    assert_equal "200", post.code
  end

  def test_fail_next_with_retry_after_header
    @server.fail_next(1, status: 429, retry_after: 1)
    response = post

    assert_equal "429", response.code
    assert_equal "1", response["Retry-After"]
    assert_equal "200", post.code
  end

  def test_always_fail_until_cleared
    @server.always_fail(status: 503)

    assert_equal "503", post.code
    assert_equal "503", post.code

    @server.clear_failures!

    assert_equal "200", post.code
  end

  def test_latency_is_applied_server_side
    @server.latency = 0.2
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    post
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :>=, 0.2
  end

  def test_records_requests_in_order
    post
    post(JSON.generate(Canned::REQUEST.merge("state" => "second")))

    assert_equal 2, @server.request_count
    assert_equal Canned.state, @server.requests.first["state"]
    assert_equal "second", @server.last_request["state"]

    @server.reset!

    assert_equal 0, @server.request_count
    assert_nil @server.last_request
  end

  def test_rejects_missing_or_empty_bearer_token
    [nil, ""].each do |token|
      response = post(token: token)

      assert_equal "401", response.code
      assert_equal "authentication_error", JSON.parse(response.body).dig("error", "type")
    end
  end

  def test_run_yields_a_started_server_and_always_stops_it
    captured = nil
    assert_raises(RuntimeError) do
      FakeJev.run do |server|
        captured = server

        assert_equal "200", post(server: server).code
        raise "boom"
      end
    end

    assert_raises(Errno::ECONNREFUSED) { post(server: captured) }
  end

  def test_shutdown_leaks_no_threads
    before = Thread.list.size
    server = FakeJev.start
    5.times { post(server: server) }
    server.stop

    assert_equal before, Thread.list.size
    assert_raises(Errno::ECONNREFUSED) { post(server: server) }
  end

  def test_the_cloudflare_envelope_wraps_answers_and_errors
    server = FakeJev.start(envelope: :cloudflare)
    body = JSON.parse(post(server: server).body)

    assert body["success"]
    assert_equal %w[urgent topic anger], body.dig("result", "answers").keys

    failed = JSON.parse(post(token: nil, server: server).body)

    refute failed["success"]
    assert_equal "missing or empty bearer token", failed.dig("errors", 0, "message")
  ensure
    server&.stop
  end
end
