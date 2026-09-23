# frozen_string_literal: true

require "rails_helper"

class ValidatorTest < JudgeRailsTest
  class FailingClient
    attr_reader :calls

    def initialize
      @calls = 0
    end

    def call(state:, questions:, model: nil) # rubocop:disable Lint/UnusedMethodArgument
      @calls += 1
      raise Judge::TransportError, "vendor unreachable"
    end
  end

  def scripted_client(probabilities, default: 0.9)
    JudgeTestSupport::RecordingClient.new do |question, name, _state|
      { "type" => "noul", "noul" => probabilities.fetch(question.instructions, default), "name" => name.to_s }
    end
  end

  def use_client(adapter)
    Judge.adapter = adapter
    @adapter = adapter
  end

  def test_refute_blocks_offending_record
    use_client(scripted_client({ "is spam" => 0.97 }))
    klass = model { validates :body, judge: { refute: "is spam" } }

    record = klass.new(body: "buy cheap watches")

    refute_predicate record, :valid?
    assert_includes record.errors[:body].first, "is spam"
  end

  def test_refute_passes_clean_record
    use_client(scripted_client({ "is spam" => 0.02 }))
    klass = model { validates :body, judge: { refute: "is spam" } }

    assert_predicate klass.new(body: "my invoice is wrong"), :valid?
  end

  def test_assert_is_the_inverse
    use_client(scripted_client({ "is written in English" => 0.04 }))
    klass = model { validates :body, judge: { assert: "is written in English" } }

    record = klass.new(body: "bonjour, ma facture est fausse")

    refute_predicate record, :valid?
    assert_includes record.errors[:body].first, "is written in English"
  end

  def test_assert_passes_when_probability_is_high
    use_client(scripted_client({ "is written in English" => 0.96 }))
    klass = model { validates :body, judge: { assert: "is written in English" } }

    assert_predicate klass.new(body: "my invoice is wrong"), :valid?
  end

  def test_threshold_is_respected
    use_client(scripted_client({ "is spam" => 0.6 }))
    lenient = model { validates :body, judge: { refute: "is spam", threshold: 0.8 } }
    strict = model { validates :body, judge: { refute: "is spam", threshold: 0.5 } }

    assert_predicate lenient.new(body: "hello"), :valid?
    refute_predicate strict.new(body: "hello"), :valid?
  end

  def test_declaring_both_refute_and_assert_raises_at_declaration_time
    error = assert_raises(ArgumentError) do
      model { validates :body, judge: { refute: "is spam", assert: "is polite" } }
    end

    assert_match(/exactly one/, error.message)
  end

  def test_declaring_neither_refute_nor_assert_raises_at_declaration_time
    assert_raises(ArgumentError) do
      model { validates :body, judge: { threshold: 0.9 } }
    end
  end

  def test_invalid_on_error_raises_at_declaration_time
    assert_raises(ArgumentError) do
      model { validates :body, judge: { refute: "is spam", on_error: :explode } }
    end
  end

  def test_blank_value_costs_no_api_call
    klass = model { validates :body, judge: { refute: "is spam" } }

    assert_predicate klass.new(body: ""), :valid?
    assert_predicate klass.new(body: nil), :valid?
    assert_equal 0, adapter.call_count
  end

  def test_custom_message
    use_client(scripted_client({ "is written in English" => 0.1 }))
    klass = model do
      validates :body,
                judge: { assert: "is written in English", threshold: 0.8, message: "must be in English" }
    end

    record = klass.new(body: "bonjour")

    refute_predicate record, :valid?
    assert_equal ["must be in English"], record.errors[:body]
  end

  def test_on_error_pass_lets_the_record_through
    failing = FailingClient.new
    Judge.adapter = failing
    klass = model { validates :body, judge: { refute: "is spam" } }
    record = klass.new(body: "hello there")

    assert_predicate record, :valid?
    assert_empty record.errors[:body]
    assert_equal 1, failing.calls
  end

  def test_on_error_fail_adds_an_error
    Judge.adapter = FailingClient.new
    klass = model { validates :body, judge: { refute: "is spam", on_error: :fail } }
    record = klass.new(body: "hello there")

    refute_predicate record, :valid?
    assert_includes record.errors[:body].first, "is spam"
  end

  def test_on_error_raise_reraises_the_judge_error
    Judge.adapter = FailingClient.new
    klass = model { validates :body, judge: { refute: "is spam", on_error: :raise } }

    assert_raises(Judge::TransportError) { klass.new(body: "hello there").valid? }
  end

  def test_if_condition_is_honoured
    use_client(scripted_client({ "is spam" => 0.99 }))
    klass = model do
      validates :body, judge: { refute: "is spam" }, if: -> { channel == "email" }
    end

    assert_predicate klass.new(body: "buy watches", channel: "sms"), :valid?
    assert_equal 0, adapter.call_count

    refute_predicate klass.new(body: "buy watches", channel: "email"), :valid?
    assert_equal 1, adapter.call_count
  end

  def test_on_context_is_honoured
    use_client(scripted_client({ "is spam" => 0.99 }))
    klass = model { validates :body, judge: { refute: "is spam" }, on: :publish }
    record = klass.new(body: "buy watches")

    assert_predicate record, :valid?
    assert_equal 0, adapter.call_count
    refute record.valid?(:publish)
  end

  def test_two_questions_on_the_same_attribute_are_batched_into_one_call
    use_client(scripted_client({ "is spam" => 0.01, "is written in English" => 0.99 }))
    klass = model do
      validates :body, judge: { refute: "is spam" }
      validates :body, judge: { assert: "is written in English" }
    end

    assert_predicate klass.new(body: "my invoice is wrong"), :valid?
    assert_equal 1, adapter.call_count
    assert_equal 2, adapter.calls.first[:questions].size
  end

  def test_identical_question_is_not_asked_twice_in_one_pass
    use_client(scripted_client({ "is spam" => 0.01 }))
    klass = model do
      validates :body, judge: { refute: "is spam" }
      validates :body, judge: { refute: "is spam", message: "looks like spam" }
    end

    assert_predicate klass.new(body: "my invoice is wrong"), :valid?
    assert_equal 1, adapter.call_count
  end

  def test_validation_results_are_exposed_and_not_persisted
    use_client(scripted_client({ "is spam" => 0.03 }))
    klass = model { validates :body, judge: { refute: "is spam" } }
    record = klass.new(body: "my invoice is wrong")

    assert_predicate record, :valid?
    instruction, result = record.judge_validation_results[:body].first

    assert_equal "is spam", instruction
    assert_in_delta 0.03, result.value

    record.save!

    assert_empty klass.find(record.id).judge_validation_results
  end

  def test_results_are_reset_between_validation_passes
    use_client(scripted_client({ "is spam" => 0.03 }))
    klass = model { validates :body, judge: { refute: "is spam" } }
    record = klass.new(body: "my invoice is wrong")

    2.times { record.valid? }

    assert_equal 1, record.judge_validation_results[:body].size
  end

  class SpamForm
    include ActiveModel::Model

    attr_accessor :body

    validates :body, judge: { refute: "is spam" }
  end

  def test_unchanged_text_is_judged_once_across_saves
    use_client(scripted_client({ "is spam" => 0.03 }))
    klass = model { validates :body, judge: { refute: "is spam" } }
    record = klass.new(body: "my invoice is wrong")

    record.valid?
    record.save!
    record.update!(channel: "web")
    record.update!(channel: "chat")

    assert_equal 1, adapter.call_count
  end

  def test_new_text_is_judged_again
    use_client(scripted_client({ "is spam" => 0.03 }))
    klass = model { validates :body, judge: { refute: "is spam" } }
    record = klass.create!(body: "my invoice is wrong")
    record.update!(body: "my invoice is still wrong")

    assert_equal 2, adapter.call_count
  end

  def test_reload_forgets_cached_judgments
    use_client(scripted_client({ "is spam" => 0.03 }))
    klass = model { validates :body, judge: { refute: "is spam" } }
    record = klass.create!(body: "my invoice is wrong")
    record.reload.valid?

    assert_equal 2, adapter.call_count
  end

  def test_a_failed_call_is_retried_on_the_next_pass
    failing = FailingClient.new
    use_client(failing)
    klass = model { validates :body, judge: { refute: "is spam" } }
    record = klass.new(body: "my invoice is wrong")

    2.times { record.valid? }

    assert_equal 2, failing.calls
  end

  def test_prefetch_sees_text_after_before_validation_normalizers
    use_client(scripted_client({}, default: 0.03))
    klass = model do
      before_validation { self.body = body.strip }
      validates :body, judge: { refute: "is spam" }
      validates :body, judge: { refute: "is abusive" }
    end

    klass.create!(body: "  my invoice is wrong  ")

    assert_equal 1, adapter.call_count
    assert_equal(["my invoice is wrong"], adapter.calls.map { |c| c[:state] })
  end

  def test_a_plain_active_model_object_can_be_validated
    use_client(scripted_client({ "is spam" => 0.97 }))
    form = SpamForm.new(body: "buy cheap watches")

    refute_predicate form, :valid?
    refute_predicate form, :valid?
    assert_equal 1, adapter.call_count
  end

  def test_a_non_judge_error_in_a_batch_is_not_swallowed
    use_client(JudgeTestSupport::RecordingClient.new { raise ArgumentError, "adapter bug" })
    klass = model do
      validates :body, judge: { refute: "is spam" }
      validates :body, judge: { refute: "is abusive" }
    end

    assert_raises(ArgumentError) { klass.new(body: "hello").valid? }
  end

  def test_an_array_validation_context_is_matched
    use_client(scripted_client({ "is spam" => 0.97 }))
    klass = model { validates :body, judge: { refute: "is spam" }, on: :create }

    refute klass.new(body: "buy cheap watches").valid?(%i[create review])
  end

  def test_only_the_current_text_stays_cached
    use_client(scripted_client({ "is spam" => 0.03 }))
    klass = model { validates :body, judge: { refute: "is spam" } }
    record = klass.new(body: "first")
    5.times do |i|
      record.body = "edit #{i}"
      record.valid?
    end

    assert_equal 1, record.instance_variable_get(:@judge_judgments).size
  end

  def test_a_plain_active_model_object_keeps_one_judgment_per_attribute
    use_client(scripted_client({ "is spam" => 0.03 }))
    form = SpamForm.new
    5.times do |i|
      form.body = "edit #{i}"
      form.valid?
    end

    assert_equal 1, form.instance_variable_get(:@judge_judgments).size
  end

  def test_a_skipped_validation_never_reads_its_attribute
    use_client(scripted_client({}, default: 0.02))
    klass = model do
      validates :body, judge: { refute: "is spam" }
      validates :subject, judge: { refute: "is rude" }, if: -> { false }
      define_method(:subject) { raise "must not be read" }
    end

    assert_predicate klass.new(body: "hello"), :valid?
  end

  def test_a_copy_does_not_share_the_judgment_cache
    klass = model { validates :body, judge: { refute: "is spam" } }
    original = klass.new(body: "first text")
    original.valid?
    copy = original.dup

    refute_same original.instance_variable_get(:@judge_judgments),
                copy.instance_variable_get(:@judge_judgments)
  end

  def test_a_one_argument_lambda_runs_against_the_record
    use_client(scripted_client({ "is spam" => 0.97 }))
    klass = model { validates :body, judge: { refute: "is spam" }, if: ->(_ticket) { channel == "web" } }

    refute_predicate klass.new(body: "buy watches", channel: "web"), :valid?
  end

  def test_strict_raises
    use_client(scripted_client({ "is spam" => 0.97 }))
    klass = model { validates :body, judge: { refute: "is spam" }, strict: true }

    assert_raises(ActiveModel::StrictValidationFailed) { klass.new(body: "buy watches").valid? }
  end

  def test_errors_carry_a_type_and_the_instruction
    use_client(scripted_client({ "is spam" => 0.97 }))
    record = model { validates :body, judge: { refute: "is spam" } }.new(body: "buy watches")
    record.valid?

    assert record.errors.of_kind?(:body, :judge_refuted)
    assert_equal "is spam", record.errors.details[:body].first[:instruction]
  end

  def test_a_frozen_form_object_can_be_validated
    skip "ActiveModel 7.2 cannot validate any frozen object" if ActiveModel.version < Gem::Version.new("8.0")
    use_client(scripted_client({ "is spam" => 0.02 }))

    assert_predicate SpamForm.new(body: "hello").freeze, :valid?
  end
end
