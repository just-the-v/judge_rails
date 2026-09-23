# frozen_string_literal: true

require "test_helper"

class FacadeTest < Minitest::Test
  def setup
    @server = FakeJev.start
    Judge.reset_config!
    Judge.configure do |c|
      c.api_key = "test-key"
      c.base_url = @server.url
    end
  end

  def teardown
    @server&.stop
    Judge.reset_config!
  end

  def test_client_resolves_without_an_explicit_require
    assert_kind_of Class, Judge::Client
    assert_respond_to Judge::Client.new, :call
  end

  def test_a_single_question_returns_a_result
    result = Judge.ask(Judge.noul("Does this convey urgency?"), text: "payouts failing for 3 days")

    assert_instance_of Judge::Result, result
    assert_equal "noul", result.type
    assert_includes 0.0..1.0, result.value
  end

  def test_a_bare_string_is_treated_as_a_noul
    result = Judge.ask("Does this convey urgency?", text: "help")

    assert_equal "noul", result.type
    assert_equal "Does this convey urgency?", @server.last_request["questions"]["answer"]["instructions"]
  end

  def test_many_questions_travel_in_one_call
    results = Judge.ask({
                          urgency: Judge.noul("Does this need a human within the hour?"),
                          department: Judge.choice("Which team?", %w[billing technical sales]),
                          frustration: Judge.score("How frustrated?", ["Calm", "Frustrated", "Very angry"])
                        }, text: "My payouts have been failing for 3 days and nobody replied.")

    assert_instance_of Judge::ResultSet, results
    assert_equal 1, @server.request_count
    assert_equal %i[urgency department frustration], results.names
    assert_includes %w[billing technical sales], results[:department].value
    assert_equal(1, results.count { |r| r.name == :urgency })
  end

  def test_an_array_uses_question_names_then_positional_fallbacks
    results = Judge.ask([Judge.noul("urgent?", name: :urgency), Judge.noul("spam?")], text: "hello")

    assert_equal %i[urgency q1], results.names
  end

  def test_the_payload_matches_the_wire_format
    Judge.ask({ dept: Judge.choice("Which team?", { billing: "money", technical: "bugs" }) },
              text: "refund please")
    body = @server.last_request

    assert_equal "refund please", body["state"]
    assert_equal "jev-latest", body["model"]
    assert_equal({ "type" => "choice", "instructions" => "Which team?",
                   "criteria" => { "billing" => "money", "technical" => "bugs" } },
                 body["questions"]["dept"])
  end

  def test_results_carry_usage_model_and_latency
    results = Judge.ask({ a: Judge.noul("urgent?") }, text: "hi")

    assert_equal "jev-1.13.0", results.model
    assert_operator results.usage.total, :>, 0
    assert_operator results.latency, :>=, 0
  end

  def test_the_same_text_yields_the_same_judgment
    a = Judge.ask("urgent?", text: "identical")
    b = Judge.ask("urgent?", text: "identical")

    assert_in_delta a.value, b.value
  end

  def test_missing_api_key_raises_before_any_request
    Judge.config.api_key = nil

    assert_raises(Judge::ConfigurationError) { Judge.ask("urgent?", text: "hi") }
    assert_equal 0, @server.request_count
  end

  def test_empty_input_is_rejected
    assert_raises(ArgumentError) { Judge.ask({}, text: "hi") }
    assert_raises(ArgumentError) { Judge.ask(42, text: "hi") }
  end

  def test_a_server_error_surfaces_after_retries
    @server.always_fail(status: 503)

    assert_raises(Judge::ServerError) { Judge.ask("urgent?", text: "hi") }
  end

  def test_a_transient_failure_is_retried
    @server.fail_next(1, status: 500)
    result = Judge.ask("urgent?", text: "hi")

    assert_equal "noul", result.type
    assert_equal 2, @server.request_count
  end
end
