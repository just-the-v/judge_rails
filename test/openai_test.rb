# frozen_string_literal: true

require "test_helper"
require "judge/openai"
require_relative "support/stub_server"

class OpenAITest < Minitest::Test
  ANSWERS = {
    "urgent" => { "type" => "predicate", "name" => "urgent", "probability" => 0.98 },
    "team" => { "type" => "choice", "name" => "team", "choice" => "technical", "confidence" => 0.9,
                "probabilities" => [{ "value" => "billing", "probability" => 0.05 },
                                    { "value" => "technical", "probability" => 0.95 }] },
    "severity" => { "type" => "score", "name" => "severity", "score" => 1.91, "confidence" => 0.91,
                    "probabilities" => [{ "value" => 0, "label" => "Minor", "probability" => 0.0 },
                                        { "value" => 1, "label" => "Major", "probability" => 0.09 },
                                        { "value" => 2, "label" => "Critical", "probability" => 0.91 }] }
  }.freeze

  def setup
    @servers = []
  end

  def teardown
    @servers.each(&:shutdown)
    Judge.reset_config!
  end

  def serve(answers: ANSWERS, &handler)
    handler ||= lambda do |request, _|
      names = request.json["questions"].map { |q| q["name"] }
      body = { "model" => "gpt-6-luna", "answers" => names.map { |n| answers.fetch(n) },
               "usage" => { "input_tokens" => 397, "output_tokens" => 0 } }
      [200, {}, JSON.generate(body)]
    end
    StubServer.new(&handler).tap { |server| @servers << server }
  end

  def config
    Judge::Configuration.new.tap do |c|
      c.adapter = :openai
      c.api_key = "jev-key"
      c.openai_api_key = "sk-test"
      c.max_retries = 1
    end
  end

  def client(server, cfg = config)
    Judge::OpenAI.new(config: cfg, sleeper: ->(_) {}, url: server.url)
  end

  def questions
    { urgent: Judge.noul("Is this urgent?"),
      team: Judge.choice("Which team?", { billing: "Payments", technical: "Outages" }),
      severity: Judge.score("How severe?", %w[Minor Major Critical]) }
  end

  def test_translates_the_questions_and_reads_typed_answers
    server = serve
    set = client(server).call(state: "Checkout is down", questions: questions)
    sent = server.requests.first.json

    assert_equal "Bearer sk-test", server.requests.first.headers["authorization"]
    assert_equal({ "model" => "gpt-6-luna", "input" => "Checkout is down" }, sent.slice("model", "input"))
    assert_equal(%w[predicate choice score], sent["questions"].map { |q| q["type"] })
    assert_equal([{ "value" => "billing", "description" => "Payments" },
                  { "value" => "technical", "description" => "Outages" }], sent["questions"][1]["choices"])
    assert_equal([{ "label" => "Minor" }, { "label" => "Major" }, { "label" => "Critical" }],
                 sent["questions"][2]["levels"])

    assert_in_delta 0.98, set[:urgent].probability
    assert_nil set[:urgent].confidence
    assert_equal "technical", set[:team].value
    assert_in_delta 0.95, set[:team].probability
    assert_in_delta 0.95, set[:team].probability_of(:technical)
    assert_equal 2, set[:severity].level
    assert_equal "Critical", set[:severity].label
    assert_in_delta 0.91, set[:severity].probability
    assert_equal "gpt-6-luna", set.model
    assert_equal 397, set.usage.input_tokens
  end

  def test_answers_are_matched_by_name_not_position
    server = serve do |_, _|
      body = { "model" => "gpt-6-luna", "answers" => [ANSWERS["team"], ANSWERS["urgent"]] }
      [200, {}, JSON.generate(body)]
    end
    set = client(server).call(state: "x", questions: questions.slice(:urgent, :team))

    assert_in_delta 0.98, set[:urgent].probability
    assert_equal "technical", set[:team].value
  end

  def test_structured_state_and_criteria_travel_as_json_strings
    server = serve
    noul = Judge.noul("Urgent?", { true: "needs a human today", false: "can wait" })
    billing = { what: "Payments", examples: ["refund"] }
    choice = Judge.choice("Which team?", { billing: billing, technical: nil })
    client(server).call(state: { message: "hi" }, questions: { urgent: noul, team: choice })
    sent = server.requests.first.json

    assert_equal '{"message":"hi"}', sent["input"]
    assert_equal "Urgent?\n\nCriteria: {\"true\":\"needs a human today\",\"false\":\"can wait\"}",
                 sent["questions"][0]["instructions"]
    assert_equal [{ "value" => "billing", "description" => '{"what":"Payments","examples":["refund"]}' },
                  { "value" => "technical" }], sent["questions"][1]["choices"]
  end

  def test_a_refusal_names_the_question
    server = serve(answers: ANSWERS.merge("urgent" => { "type" => "refusal", "name" => "urgent" }))
    error = assert_raises(Judge::RefusalError) do
      client(server).call(state: "x", questions: questions.slice(:urgent))
    end

    assert_equal :urgent, error.question_name
    assert_kind_of Judge::InvalidResponseError, error
  end

  def test_a_model_it_does_not_serve_raises_before_any_request
    server = serve
    error = assert_raises(Judge::ConfigurationError) do
      client(server).call(state: "x", questions: questions.slice(:urgent), model: "jev-latest")
    end

    assert_includes error.message, "gpt-6-luna"
    assert_empty server.requests
  end

  def test_a_missing_key_names_the_variable
    server = serve
    cfg = config.tap { |c| c.openai_api_key = nil }
    error = assert_raises(Judge::ConfigurationError) do
      client(server, cfg).call(state: "x", questions: questions.slice(:urgent))
    end

    assert_includes error.message, "OPENAI_API_KEY"
  end

  def test_openai_errors_map_to_the_same_classes
    body = JSON.generate("error" => { "message" => "Unknown parameter: 'questions[0].criteria'.",
                                      "type" => "invalid_request_error" })
    server = serve { |_, _| [400, {}, body] }
    error = assert_raises(Judge::InvalidRequestError) do
      client(server).call(state: "x", questions: questions.slice(:urgent))
    end

    assert_equal "Judge API returned 400: Unknown parameter: 'questions[0].criteria'.", error.message
  end

  def test_a_server_error_is_retried
    server = serve do |_, index|
      next [503, {}, "{}"] if index.zero?

      [200, {}, JSON.generate("model" => "gpt-6-luna", "answers" => [ANSWERS["urgent"]])]
    end
    set = client(server).call(state: "x", questions: questions.slice(:urgent))

    assert_in_delta 0.98, set[:urgent].probability
    assert_equal 2, server.requests.size
  end

  def test_a_wrong_answer_type_or_shape_is_an_invalid_response
    wrong_type = serve(answers: ANSWERS.merge("urgent" => ANSWERS["team"].merge("name" => "urgent")))
    hash_probabilities = ANSWERS["team"].merge("probabilities" => { "a" => 1 })
    bad_shape = serve(answers: ANSWERS.merge("team" => hash_probabilities))

    assert_raises(Judge::InvalidResponseError) do
      client(wrong_type).call(state: "x", questions: questions.slice(:urgent))
    end
    assert_raises(Judge::InvalidResponseError) do
      client(bad_shape).call(state: "x", questions: questions.slice(:team))
    end
  end

  def test_the_adapter_and_its_default_model
    assert_instance_of Judge::OpenAI, Judge::Adapter.build(:openai)
    assert_equal "gpt-6-luna", config.model
    refute_includes config.inspect, "sk-test"
    refute_includes client(serve).inspect, "sk-test"
  end
end

class OpenAIConfigurationTest < Minitest::Test
  VARS = %w[JUDGE_ADAPTER JEV_MODEL OPENAI_API_KEY].freeze

  def with_env(vars)
    previous = VARS.to_h { |k| [k, ENV.fetch(k, nil)] }
    VARS.each { |k| ENV.delete(k) }
    vars.each { |k, v| ENV[k] = v }
    yield Judge::Configuration.new
  ensure
    previous.each { |k, v| ENV[k] = v }
  end

  def test_the_environment_picks_openai_and_its_model
    with_env("JUDGE_ADAPTER" => "openai", "OPENAI_API_KEY" => " sk-env ") do |c|
      assert_equal :openai, c.adapter
      assert_equal "gpt-6-luna", c.model
      assert_equal "sk-env", c.openai_api_key
    end
  end

  def test_jev_and_clef_defaults_are_unchanged
    with_env({}) { |c| assert_equal "jev-latest", c.model }
    with_env("JUDGE_ADAPTER" => "clef") { |c| assert_equal "clef", c.model }
  end
end
