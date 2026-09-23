# frozen_string_literal: true

require "rails_helper"

class JudgeJobsTest < JudgeRailsTest
  def setup
    super
    @enqueued = []
    Judge::Rails::Jobs.enqueuer = ->(payload) { @enqueued << payload }
  end

  def teardown
    Judge::Rails::Jobs.reset_enqueuer!
    super
  end

  attr_reader :enqueued

  def exploding_client(on: nil)
    JudgeTestSupport::RecordingClient.new do |_question, _name, state|
      raise Judge::APIError, "boom" if on.nil? || state.to_s.include?(on)

      nil
    end
  end

  def run_payload(payload, adapter: nil)
    Judge::Rails::Jobs.perform(payload, adapter: adapter)
  end

  def test_inline_computes_during_save
    klass = model do
      judge_source :body
      judge_attribute :urgency, JudgeTestSupport::QUESTIONS[:urgency].call, sync: true
    end

    record = klass.create!(body: "server is down")

    assert_in_delta 0.91, record.reload.urgency
    assert_equal 1, adapter.call_count
    assert_empty enqueued
  end

  def test_async_enqueues_once_per_save
    klass = async_model
    record = klass.create!(body: "cannot log in")

    assert_equal 1, enqueued.size
    payload = enqueued.first

    assert_equal [record.id], payload.ids
    assert_equal %i[urgency], payload.names
    assert_equal 0, adapter.call_count
  end

  def test_noop_save_enqueues_nothing
    klass = async_model
    record = klass.create!(body: "cannot log in")
    run_payload(enqueued.first)
    enqueued.clear

    record.reload.update!(channel: "email")

    assert_empty enqueued
  end

  def test_callbacks_false_never_enqueues
    klass = model do
      judge_source :body
      judge_attribute :urgency, JudgeTestSupport::QUESTIONS[:urgency].call, callbacks: false
    end

    record = klass.create!(body: "cannot log in")
    record.update!(body: "still cannot log in")

    assert_empty enqueued
    assert_nil record.reload.urgency
  end

  def test_backfill_shares_one_call_across_attributes
    klass = backfill_model
    250.times { |i| klass.create!(body: "ticket #{i}") }
    adapter.reset!

    summary = klass.judge_refresh_all

    assert_equal 250, summary.records
    assert_equal 250, summary.computed
    assert_equal 250, summary.calls
    assert_equal 250, adapter.call_count
    assert_equal 250, klass.where.not(urgency: nil).where.not(intent: nil).count
  end

  def test_backfill_counts_failures_and_continues
    klass = backfill_model
    %w[fine boom-here also-fine].each { |body| klass.create!(body: body) }
    Judge.adapter = exploding_client(on: "boom")

    summary = klass.judge_refresh_all

    assert_equal 3, summary.records
    assert_equal 2, summary.computed
    assert_equal 1, summary.failed
    assert_equal 2, klass.where.not(urgency: nil).count
  end

  def test_resume_skips_computed_records
    klass = backfill_model
    3.times { |i| klass.create!(body: "ticket #{i}") }
    klass.judge_refresh_all
    adapter.reset!

    summary = klass.judge_refresh_all(force: true, resume: true)

    assert_equal 3, summary.skipped
    assert_equal 0, summary.computed
    assert_equal 0, summary.calls
    assert_equal 0, adapter.call_count
  end

  def test_failed_compute_keeps_previous_value_and_does_not_raise
    klass = async_model
    record = klass.create!(body: "server is down")
    run_payload(enqueued.first)
    enqueued.clear
    record.reload

    assert_in_delta 0.91, record.urgency

    Judge.adapter = exploding_client
    record.update!(body: "something else entirely")

    assert_equal 1, enqueued.size
    run_payload(enqueued.first)

    record.reload

    assert_in_delta 0.91, record.urgency
    assert_predicate record, :judge_stale?
  end

  def test_inline_on_error_raise_propagates
    klass = model do
      judge_source :body
      judge_attribute :urgency, JudgeTestSupport::QUESTIONS[:urgency].call, sync: true, on_error: :raise
    end
    Judge.adapter = exploding_client

    assert_raises(Judge::APIError) { klass.create!(body: "server is down") }
  end

  def test_inline_on_error_pass_swallows
    klass = model do
      judge_source :body
      judge_attribute :urgency, JudgeTestSupport::QUESTIONS[:urgency].call, sync: true
    end
    Judge.adapter = exploding_client

    record = klass.create!(body: "server is down")

    assert_nil record.reload.urgency
  end

  def test_refresh_later_enqueues_manually
    klass = model do
      judge_source :body
      judge_attribute :urgency, JudgeTestSupport::QUESTIONS[:urgency].call, callbacks: false
    end
    record = klass.create!(body: "cannot log in")

    record.judge_refresh_later

    assert_equal 1, enqueued.size
    run_payload(enqueued.first)

    assert_in_delta 0.91, record.reload.urgency
  end

  def test_refresh_job_hands_a_retryable_failure_back_to_active_job
    record = named_async_model.create!(body: "cannot log in")
    Judge.adapter = JudgeTestSupport::RecordingClient.new { raise Judge::ServerError, "503" }
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear

    Judge::Rails::RefreshJob.perform_now(record.class.name, record.id, ["urgency"])

    assert_equal 1, ActiveJob::Base.queue_adapter.enqueued_jobs.size
  end

  def test_refresh_job_swallows_a_failure_that_retrying_cannot_fix
    record = named_async_model.create!(body: "cannot log in")
    Judge.adapter = exploding_client
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear

    Judge::Rails::RefreshJob.perform_now(record.class.name, record.id, ["urgency"])

    assert_empty ActiveJob::Base.queue_adapter.enqueued_jobs
  end

  def test_a_source_that_changes_on_save_does_not_loop
    klass = model do
      judge_attribute :urgency, Judge.noul("urgent?"), source: -> { "#{body} #{updated_at.to_f}" }
    end
    record = klass.create!(body: "down")
    run_payload(enqueued.shift)

    assert_empty enqueued
    assert_equal 1, adapter.call_count
    assert_predicate record.reload, :judge_stale?
  end

  def test_refreshing_one_attribute_still_enqueues_another_that_went_stale
    klass = model do
      judge_source :body
      judge_attribute :urgency, Judge.noul("urgent?")
      judge_attribute :intent, JudgeTestSupport::QUESTIONS[:intent].call
    end
    record = klass.create!(body: "down")
    enqueued.clear

    record.body = "up again"
    record.judge_refresh!(:urgency)

    assert_equal [%i[intent]], enqueued.map(&:names)
  end

  def test_blanking_the_source_of_an_async_attribute_clears_it_without_a_job
    record = async_model.create!(body: "down")
    run_payload(enqueued.shift)
    record.reload.update!(body: "")
    record.update!(channel: "web")

    assert_empty enqueued
    assert_nil record.reload.urgency
    assert_equal 1, adapter.call_count
  end

  def test_refresh_bang_computes_sync_attributes_with_the_given_adapter
    klass = model do
      judge_source :body
      judge_attribute :urgency, Judge.noul("urgent?"), sync: true
      judge_attribute :intent, JudgeTestSupport::QUESTIONS[:intent].call, callbacks: false
    end
    record = klass.create!(body: "down")
    record.update_columns(body: "up again")
    per_request = JudgeTestSupport::RecordingClient.new
    adapter.reset!

    record.judge_refresh!(:intent, adapter: per_request)

    assert_equal 0, adapter.call_count
    assert_equal 2, per_request.call_count
  end

  private

  def named_async_model
    self.class.send(:remove_const, :NamedTicket) if self.class.const_defined?(:NamedTicket, false)
    self.class.const_set(:NamedTicket, async_model)
  end

  def async_model
    model do
      judge_source :body
      judge_attribute :urgency, JudgeTestSupport::QUESTIONS[:urgency].call
    end
  end

  def backfill_model
    model do
      judge_source :body
      judge_attribute :urgency, JudgeTestSupport::QUESTIONS[:urgency].call, callbacks: false
      judge_attribute :intent, JudgeTestSupport::QUESTIONS[:intent].call, callbacks: false
      judge_attribute :frustration, JudgeTestSupport::QUESTIONS[:frustration].call, callbacks: false
    end
  end
end
