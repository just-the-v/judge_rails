# frozen_string_literal: true

require "rails_helper"

class ValidatorTest < JevRailsTest
  class FailingClient
    attr_reader :calls

    def initialize
      @calls = 0
    end

    def call(state:, questions:, model: nil) # rubocop:disable Lint/UnusedMethodArgument
      @calls += 1
      raise Jev::TransportError, "vendor unreachable"
    end
  end

  def scripted_client(probabilities, default: 0.9)
    JevTestSupport::RecordingClient.new do |question, name, _state|
      { "type" => "noul", "noul" => probabilities.fetch(question.instructions, default), "name" => name.to_s }
    end
  end

  def use_client(client)
    Jev.client = client
    @client = client
  end

  def test_refute_blocks_offending_record
    use_client(scripted_client({ "is spam" => 0.97 }))
    klass = model { validates :body, jev: { refute: "is spam" } }

    record = klass.new(body: "buy cheap watches")

    refute_predicate record, :valid?
    assert_includes record.errors[:body].first, "is spam"
  end

  def test_refute_passes_clean_record
    use_client(scripted_client({ "is spam" => 0.02 }))
    klass = model { validates :body, jev: { refute: "is spam" } }

    assert_predicate klass.new(body: "my invoice is wrong"), :valid?
  end

  def test_assert_is_the_inverse
    use_client(scripted_client({ "is written in English" => 0.04 }))
    klass = model { validates :body, jev: { assert: "is written in English" } }

    record = klass.new(body: "bonjour, ma facture est fausse")

    refute_predicate record, :valid?
    assert_includes record.errors[:body].first, "is written in English"
  end

  def test_assert_passes_when_probability_is_high
    use_client(scripted_client({ "is written in English" => 0.96 }))
    klass = model { validates :body, jev: { assert: "is written in English" } }

    assert_predicate klass.new(body: "my invoice is wrong"), :valid?
  end

  def test_threshold_is_respected
    use_client(scripted_client({ "is spam" => 0.6 }))
    lenient = model { validates :body, jev: { refute: "is spam", threshold: 0.8 } }
    strict = model { validates :body, jev: { refute: "is spam", threshold: 0.5 } }

    assert_predicate lenient.new(body: "hello"), :valid?
    refute_predicate strict.new(body: "hello"), :valid?
  end

  def test_declaring_both_refute_and_assert_raises_at_declaration_time
    error = assert_raises(ArgumentError) do
      model { validates :body, jev: { refute: "is spam", assert: "is polite" } }
    end

    assert_match(/exactly one/, error.message)
  end

  def test_declaring_neither_refute_nor_assert_raises_at_declaration_time
    assert_raises(ArgumentError) do
      model { validates :body, jev: { threshold: 0.9 } }
    end
  end

  def test_invalid_on_error_raises_at_declaration_time
    assert_raises(ArgumentError) do
      model { validates :body, jev: { refute: "is spam", on_error: :explode } }
    end
  end

  def test_blank_value_costs_no_api_call
    klass = model { validates :body, jev: { refute: "is spam" } }

    assert_predicate klass.new(body: ""), :valid?
    assert_predicate klass.new(body: nil), :valid?
    assert_equal 0, client.call_count
  end

  def test_custom_message
    use_client(scripted_client({ "is written in English" => 0.1 }))
    klass = model do
      validates :body, jev: { assert: "is written in English", threshold: 0.8, message: "must be in English" }
    end

    record = klass.new(body: "bonjour")

    refute_predicate record, :valid?
    assert_equal ["must be in English"], record.errors[:body]
  end

  def test_on_error_pass_lets_the_record_through
    failing = FailingClient.new
    Jev.client = failing
    klass = model { validates :body, jev: { refute: "is spam" } }
    record = klass.new(body: "hello there")

    assert_predicate record, :valid?
    assert_empty record.errors[:body]
    assert_equal 1, failing.calls
  end

  def test_on_error_fail_adds_an_error
    Jev.client = FailingClient.new
    klass = model { validates :body, jev: { refute: "is spam", on_error: :fail } }
    record = klass.new(body: "hello there")

    refute_predicate record, :valid?
    assert_includes record.errors[:body].first, "is spam"
  end

  def test_on_error_raise_reraises_the_jev_error
    Jev.client = FailingClient.new
    klass = model { validates :body, jev: { refute: "is spam", on_error: :raise } }

    assert_raises(Jev::TransportError) { klass.new(body: "hello there").valid? }
  end

  def test_if_condition_is_honoured
    use_client(scripted_client({ "is spam" => 0.99 }))
    klass = model do
      validates :body, jev: { refute: "is spam" }, if: -> { channel == "email" }
    end

    assert_predicate klass.new(body: "buy watches", channel: "sms"), :valid?
    assert_equal 0, client.call_count

    refute_predicate klass.new(body: "buy watches", channel: "email"), :valid?
    assert_equal 1, client.call_count
  end

  def test_on_context_is_honoured
    use_client(scripted_client({ "is spam" => 0.99 }))
    klass = model { validates :body, jev: { refute: "is spam" }, on: :publish }
    record = klass.new(body: "buy watches")

    assert_predicate record, :valid?
    assert_equal 0, client.call_count
    refute record.valid?(:publish)
  end

  def test_two_questions_on_the_same_attribute_are_batched_into_one_call
    use_client(scripted_client({ "is spam" => 0.01, "is written in English" => 0.99 }))
    klass = model do
      validates :body, jev: { refute: "is spam" }
      validates :body, jev: { assert: "is written in English" }
    end

    assert_predicate klass.new(body: "my invoice is wrong"), :valid?
    assert_equal 1, client.call_count
    assert_equal 2, client.calls.first[:questions].size
  end

  def test_identical_question_is_not_asked_twice_in_one_pass
    use_client(scripted_client({ "is spam" => 0.01 }))
    klass = model do
      validates :body, jev: { refute: "is spam" }
      validates :body, jev: { refute: "is spam", message: "looks like spam" }
    end

    assert_predicate klass.new(body: "my invoice is wrong"), :valid?
    assert_equal 1, client.call_count
  end

  def test_validation_results_are_exposed_and_not_persisted
    use_client(scripted_client({ "is spam" => 0.03 }))
    klass = model { validates :body, jev: { refute: "is spam" } }
    record = klass.new(body: "my invoice is wrong")

    assert_predicate record, :valid?
    instruction, result = record.jev_validation_results[:body].first

    assert_equal "is spam", instruction
    assert_in_delta 0.03, result.value

    record.save!

    assert_empty klass.find(record.id).jev_validation_results
  end

  def test_results_are_reset_between_validation_passes
    use_client(scripted_client({ "is spam" => 0.03 }))
    klass = model { validates :body, jev: { refute: "is spam" } }
    record = klass.new(body: "my invoice is wrong")

    2.times { record.valid? }

    assert_equal 1, record.jev_validation_results[:body].size
  end
end
