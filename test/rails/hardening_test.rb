# frozen_string_literal: true

require "rails_helper"

class HardeningTest < JudgeRailsTest
  def failing_client(error = Judge::ServerError.new("down", status: 503))
    Class.new do
      define_method(:call) { |**| raise error }
    end.new
  end

  def test_on_error_is_rejected_on_an_attribute_that_cannot_honour_it
    error = assert_raises(ArgumentError) do
      model do
        judge_source { body }
        judge_attribute :urgency, Judge.noul("urgent?"), on_error: :fail
      end
    end

    assert_match(/only applies to a synchronous attribute/, error.message)
  end

  def test_on_error_is_allowed_on_a_sync_attribute
    klass = model do
      judge_source { body }
      judge_attribute :urgency, Judge.noul("urgent?"), sync: true, on_error: :fail
    end

    assert_equal :fail, klass.judge_definition(:urgency).on_error
  end

  def test_inline_pass_lets_the_save_through_during_an_outage
    klass = model do
      judge_source { body }
      judge_attribute :urgency, Judge.noul("urgent?"), sync: true
    end
    Judge.adapter = failing_client
    record = klass.new(body: "payouts down")

    assert record.save
    assert_nil record.urgency
  end

  def test_inline_fail_blocks_the_save_during_an_outage
    klass = model do
      judge_source { body }
      judge_attribute :urgency, Judge.noul("urgent?"), sync: true, on_error: :fail
    end
    Judge.adapter = failing_client
    record = klass.new(body: "payouts down")

    refute record.save
    assert_match(/could not judge urgency/, record.errors.full_messages.join)
  end

  def test_inline_raise_propagates_during_an_outage
    klass = model do
      judge_source { body }
      judge_attribute :urgency, Judge.noul("urgent?"), sync: true, on_error: :raise
    end
    Judge.adapter = failing_client

    assert_raises(Judge::ServerError) { klass.new(body: "payouts down").save }
  end

  def test_on_error_applies_to_the_attributes_in_the_failed_call_only
    klass = model do
      judge_attribute :urgency, Judge.noul("urgent?"), source: :body, sync: true, on_error: :raise
      judge_attribute :intent, Judge.choice("what?", %w[billing technical]), source: :subject, sync: true
    end
    calls = []
    Judge.adapter = Class.new do
      define_method(:call) do |state:, questions:, model: nil|
        calls << state
        raise Judge::ServerError.new("down", status: 503) if state == "body text"

        JudgeTestSupport::RecordingClient.new.call(state: state, questions: questions, model: model)
      end
    end.new

    assert_raises(Judge::ServerError) { klass.new(subject: "subject text", body: "body text").save }
    assert_includes calls, "body text"
  end

  def test_decide_rejects_a_band_where_no_probability_can_be_negative
    klass = model do
      judge_source { body }
      judge_attribute :urgency, Judge.noul("urgent?"), sync: true
    end
    record = klass.new(body: "hello", urgency: 0.5)

    assert_raises(ArgumentError) { record.judge_decide(:urgency, above: 0.3, below: 0.7) }
    assert_equal :unsure, record.judge_decide(:urgency, above: 0.9, below: 0.1)
  end

  def test_decide_without_below_never_produces_an_unreachable_band
    klass = model do
      judge_source { body }
      judge_attribute :urgency, Judge.noul("urgent?"), sync: true
    end

    assert_equal :no, klass.new(body: "x", urgency: 0.1).judge_decide(:urgency, above: 0.3)
    assert_equal :yes, klass.new(body: "x", urgency: 0.9).judge_decide(:urgency, above: 0.3)
  end
end
