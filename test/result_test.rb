# frozen_string_literal: true

require "test_helper"
require "json"

class ResultTest < Minitest::Test
  LIVE_RESPONSE = JSON.parse(<<~JSON)
    {"model":"jev-1.13.0","answers":{
      "is_urgent":{"type":"noul","noul":0.96},
      "department":{"type":"choice","choice":"billing","confidence":0.88,
        "probabilities":{"sales":0.0,"billing":0.92,"technical":0.08}},
      "frustration":{"type":"score","score":1.22,"confidence":0.67,
        "legend":{"0":"Calm","1":"Frustrated","2":"Very angry"},
        "probabilities":{"0":0.0,"1":0.78,"2":0.22}}},
      "usage":{"input_tokens":430,"output_tokens":73}}
  JSON

  def questions
    {
      is_urgent: Judge.noul("Does this convey urgency?"),
      department: Judge.choice("Which team should handle this?", %w[billing technical sales]),
      frustration: Judge.score("How frustrated is the customer?", ["Calm", "Frustrated", "Very angry"])
    }
  end

  def set
    @set ||= Judge::ResultSet.from_response(LIVE_RESPONSE, questions: questions, latency: 0.69)
  end

  def test_noul_value_is_the_probability
    r = set[:is_urgent]

    assert_in_delta 0.96, r.value
    assert_in_delta 0.96, r.probability
    assert r.true?
    refute r.true?(0.99)
  end

  def test_choice_exposes_winner_and_distribution
    r = set[:department]

    assert_equal "billing", r.value
    assert_in_delta 0.92, r.probability
    assert_in_delta 0.88, r.confidence
    assert_in_delta 0.08, r.probability_of(:technical)
  end

  def test_score_exposes_continuous_value_level_and_label
    r = set[:frustration]

    assert_in_delta 1.22, r.value
    assert_equal 1, r.level
    assert_equal "Frustrated", r.label
    assert_in_delta 0.78, r.probability
  end

  def test_decide_returns_the_threshold_band
    assert_equal :yes, set[:is_urgent].decide(above: 0.9)
    assert_equal :unsure, set[:is_urgent].decide(above: 0.99, below: 0.1)
    assert_equal :no, set[:frustration].decide(above: 0.99, below: 0.8)
  end

  def test_true_bang_rejects_non_noul_answers
    assert_raises(ArgumentError) { set[:department].true? }
  end

  def test_result_set_metadata
    assert_equal "jev-1.13.0", set.model
    assert_equal 503, set.usage.total
    assert_equal %i[is_urgent department frustration], set.names
    assert_equal 3, set.size
    assert_in_delta 0.69, set.latency
  end

  def test_missing_answer_raises
    body = { "answers" => { "is_urgent" => { "type" => "noul", "noul" => 0.5 } } }

    assert_raises(Judge::InvalidResponseError) { Judge::ResultSet.from_response(body, questions: questions) }
  end

  def test_malformed_answer_raises
    body = { "answers" => { "is_urgent" => { "type" => "noul" } } }
    qs = { is_urgent: questions[:is_urgent] }

    assert_raises(Judge::InvalidResponseError) { Judge::ResultSet.from_response(body, questions: qs)[:is_urgent].value }
  end

  def test_malformed_answers_fail_inside_ask
    noul = Judge.noul("urgent?")
    choice = Judge.choice("team?", %w[billing technical])
    score = Judge.score("how?", %w[calm cross angry])
    [
      [noul, { "type" => "noul" }],
      [noul, { "type" => "noul", "noul" => "high" }],
      [noul, { "type" => "choice", "choice" => "billing" }],
      [choice, { "type" => "choice", "choice" => "sales" }],
      [score, { "type" => "score", "score" => 7 }]
    ].each do |question, answer|
      assert_raises(Judge::InvalidResponseError, answer.inspect) { question.coerce(answer, name: :x) }
    end
  end

  def test_from_values_accepts_symbol_keys
    question = Judge.choice("team?", %w[billing technical])
    result = Judge::Result.from_values(name: :team, type: :choice, value: "billing", question: question,
                                       probabilities: { billing: 0.8, technical: 0.2 })

    assert_in_delta 0.8, result.probability
  end

  def test_a_result_set_refuses_two_results_with_one_name
    one = Judge::Result.from_values(name: :a, type: :noul, value: 0.1)

    assert_raises(ArgumentError) { Judge::ResultSet.new([one, one]) }
  end

  def test_answers_are_deeply_frozen
    result = set[:department]

    assert_predicate result.probabilities, :frozen?
    assert_predicate set.usage, :frozen?
  end
end
