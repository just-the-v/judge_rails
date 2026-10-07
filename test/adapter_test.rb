# frozen_string_literal: true

require "test_helper"

class AdapterTest < Minitest::Test
  class FakeProvider
    attr_reader :seen

    def initialize(verdict: 0.42)
      @verdict = verdict
      @seen = []
    end

    def call(state:, questions:, model: nil)
      @seen << { state: state, model: model, names: questions.keys }
      results = questions.map do |name, question|
        Judge::Result.from_values(name: name, question: question, type: question.type,
                                  **answer_for(question))
      end
      Judge::ResultSet.new(results, model: "fake-1")
    end

    private

    def answer_for(question)
      case question.type
      when "noul" then { value: @verdict }
      when "choice" then { value: question.options.first, confidence: 0.9,
                           probabilities: question.options.to_h do |o|
                             [o, o == question.options.first ? 0.9 : 0.1]
                           end }
      when "score" then { value: 1.0, confidence: 0.7,
                          legend: question.levels.each_with_index.to_h { |l, i| [i.to_s, l] },
                          probabilities: { "0" => 0.2, "1" => 0.8 } }
      end
    end
  end

  def setup
    Judge.reset_config!
    Judge::Adapter.reset!
    Judge.adapter = nil
  end

  def teardown
    Judge.reset_config!
    Judge::Adapter.reset!
    Judge.adapter = nil
  end

  def test_the_default_adapter_is_judge
    assert_equal :jev, Judge.config.adapter
    assert_equal %i[jev clef openai], Judge::Adapter.names
    assert_instance_of Judge::Client, Judge::Adapter.build(:jev)
  end

  def test_a_registered_adapter_answers_instead
    Judge::Adapter.register(:fake) { FakeProvider.new }
    Judge.configure { |c| c.adapter = :fake }

    result = Judge.ask(Judge.noul("urgent?"), text: "the roof is on fire")

    assert_in_delta 0.42, result.value
    assert_equal "noul", result.type
  end

  def test_an_adapter_never_has_to_speak_jev_json
    Judge::Adapter.register(:fake) { FakeProvider.new }
    Judge.configure { |c| c.adapter = :fake }

    results = Judge.ask({ urgency: Judge.noul("urgent?"),
                          team: Judge.choice("who?", %w[billing technical]),
                          anger: Judge.score("how angry?", %w[Calm Furious]) },
                        text: "the roof is on fire")

    assert_in_delta 0.42, results[:urgency].value
    assert_equal "billing", results[:team].value
    assert_in_delta 0.9, results[:team].probability
    assert_equal 1, results[:anger].level
    assert_equal "Furious", results[:anger].label
  end

  def test_an_adapter_passed_per_call_beats_the_configured_one
    provider = FakeProvider.new(verdict: 0.99)

    assert_in_delta 0.99, Judge.ask(Judge.noul("urgent?"), text: "x", adapter: provider).value
    assert_equal(["x"], provider.seen.map { |call| call[:state] })
  end

  def test_an_adapter_named_per_call_is_looked_up
    Judge::Adapter.register(:fake) { FakeProvider.new }

    assert_in_delta 0.42, Judge.ask(Judge.noul("urgent?"), text: "x", adapter: :fake).probability
  end

  def test_an_unknown_adapter_says_what_is_known
    Judge.configure { |c| c.adapter = :nope }

    error = assert_raises(Judge::ConfigurationError) { Judge.ask(Judge.noul("x"), text: "y") }

    assert_match(/unknown adapter :nope/, error.message)
    assert_match(/Known: :jev/, error.message)
    assert_match(/Judge::Adapter\.register\(:nope\)/, error.message)
  end

  def test_register_demands_a_block
    assert_raises(ArgumentError) { Judge::Adapter.register(:empty) }
  end

  def test_the_adapter_is_built_once_and_memoised
    built = 0
    Judge::Adapter.register(:counted) { built += 1 and FakeProvider.new }
    Judge.configure { |c| c.adapter = :counted }

    3.times { Judge.ask(Judge.noul("x"), text: "y") }

    assert_equal 1, built
  end

  def test_the_environment_can_pick_the_adapter
    ENV["JUDGE_ADAPTER"] = "laya"
    Judge.reset_config!

    assert_equal :laya, Judge.config.adapter
  ensure
    ENV.delete("JUDGE_ADAPTER")
    Judge.reset_config!
  end

  def test_result_from_values_derives_the_probability_rather_than_taking_it
    noul = Judge::Result.from_values(name: :u, type: "noul", value: 0.8)

    assert_in_delta 0.8, noul.probability

    choice = Judge::Result.from_values(name: :t, type: "choice", value: "billing",
                                       probabilities: { "billing" => 0.7, "technical" => 0.3 })

    assert_in_delta 0.7, choice.probability
    assert_in_delta 0.3, choice.probability_of(:technical)
  end

  def test_changing_config_adapter_after_a_call_switches_adapters
    first = FakeProvider.new
    second = FakeProvider.new
    Judge::Adapter.register(:first) { first }
    Judge::Adapter.register(:second) { second }

    Judge.configure { |c| c.adapter = :first }
    Judge.ask("is it urgent?", text: "x")
    Judge.configure { |c| c.adapter = :second }
    Judge.ask("is it urgent?", text: "x")

    assert_equal 1, first.seen.size
    assert_equal 1, second.seen.size
  end

  def test_re_registering_the_configured_name_takes_effect
    first = FakeProvider.new
    second = FakeProvider.new
    Judge::Adapter.register(:swap) { first }
    Judge.configure { |c| c.adapter = :swap }
    Judge.ask("is it urgent?", text: "x")
    Judge::Adapter.register(:swap) { second }
    Judge.ask("is it urgent?", text: "x")

    assert_equal 1, second.seen.size
  end

  def test_an_adapter_object_can_be_configured_directly
    provider = FakeProvider.new
    Judge.configure { |c| c.adapter = provider }

    Judge.ask("is it urgent?", text: "x")

    assert_equal 1, provider.seen.size
  end

  def test_an_adapter_that_omits_an_answer_raises_a_judge_error
    Judge.adapter = ->(**) { Judge::ResultSet.new([]) }

    assert_raises(Judge::InvalidResponseError) { Judge.ask("is it urgent?", text: "x") }
  end

  def test_a_factory_may_resolve_another_adapter
    inner = FakeProvider.new
    Judge::Adapter.register(:inner) { inner }
    Judge::Adapter.register(:outer) { Judge::Adapter.resolve(:inner) }
    Judge.configure { |c| c.adapter = :outer }

    Judge.ask("is it urgent?", text: "x")

    assert_equal 1, inner.seen.size
  end
end
