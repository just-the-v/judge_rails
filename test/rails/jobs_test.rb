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

  def test_a_refresh_stores_judgments_without_saving_other_edits
    record = async_model.create!(body: "down", channel: "email")
    enqueued.clear

    record.channel = "web"
    record.judge_refresh!(:urgency)

    assert_in_delta 0.91, record.class.find(record.id).urgency
    assert_equal "email", record.class.find(record.id).channel
    assert_empty enqueued
  end

  def test_after_judge_refresh_runs_once_per_stored_refresh
    seen = []
    klass = model do
      judge_attribute :urgency, Judge.noul("urgent?"), source: :body, callbacks: false
      after_judge_refresh { seen << urgency }
    end
    record = klass.create!(body: "down")
    record.judge_refresh!
    record.judge_refresh!

    assert_equal [0.91], seen
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

  def test_refresh_bang_bills_only_the_adapter_it_was_given
    klass = model do
      judge_source :body
      judge_attribute :urgency, Judge.noul("urgent?"), sync: true
      judge_attribute :intent, JudgeTestSupport::QUESTIONS[:intent].call, callbacks: false
    end
    record = klass.create!(body: "down")
    record.update_columns(body: "up again")
    per_request = JudgeTestSupport::RecordingClient.new
    adapter.reset!

    record.judge_refresh!(adapter: per_request)

    assert_equal 0, adapter.call_count
    assert_equal 1, per_request.call_count
  end

  def test_a_refresh_inside_a_transaction_does_not_hide_a_later_edit
    record = async_model.create!(body: "down")
    run_payload(enqueued.shift)

    record.class.transaction do
      record.judge_refresh!(:urgency, force: true)
      record.update!(body: "new text")
    end

    assert_equal [%i[urgency]], enqueued.map(&:names)
  end

  def test_a_refresh_stores_the_judgment_on_a_row_that_fails_validation
    klass = model do
      judge_attribute :urgency, Judge.noul("urgent?"), source: :body, callbacks: false
      validates :channel, presence: true
    end
    record = klass.new(body: "down").tap { |ticket| ticket.save!(validate: false) }

    record.judge_refresh!

    assert_in_delta 0.91, klass.find(record.id).urgency
    assert_equal 1, adapter.call_count
  end

  def test_a_refresh_does_not_rerun_judge_validations
    klass = model do
      judge_attribute :urgency, Judge.noul("urgent?"), source: :body
      validates :body, judge: { refute: "is spam" }
    end
    Judge.adapter = @adapter = JudgeTestSupport::RecordingClient.new do |question, name, _state|
      { "type" => "noul", "noul" => 0.1, "name" => name.to_s } if question.instructions == "is spam"
    end
    record = klass.create!(body: "down")
    adapter.reset!

    run_payload(enqueued.shift)

    assert_equal 1, adapter.call_count
    refute_nil record.reload.urgency
  end

  def test_a_second_async_save_in_one_transaction_is_still_enqueued
    klass = model do
      judge_source :body
      judge_attribute :urgency, Judge.noul("urgent?")
      judge_attribute :intent, JudgeTestSupport::QUESTIONS[:intent].call
    end
    record = klass.create!(body: "down")
    enqueued.clear

    klass.transaction do
      record.update!(body: "site down")
      record.judge_refresh!(:urgency)
    end

    assert_equal [%i[intent]], enqueued.map(&:names)
  end

  def test_backfill_counts_a_call_that_was_sent_before_a_failure
    klass = model do
      judge_attribute :urgency, Judge.noul("urgent?"), source: :subject, callbacks: false
      judge_attribute :intent, JudgeTestSupport::QUESTIONS[:intent].call, source: :body, callbacks: false
    end
    klass.create!(subject: "subject", body: "body")
    Judge.adapter = JudgeTestSupport::RecordingClient.new do |_question, _name, state|
      raise Judge::ServerError, "503" if state == "body"
    end

    summary = klass.judge_refresh_all

    assert_equal 1, summary.failed
    assert_equal 2, summary.calls
  end

  def test_refresh_job_honours_the_queue_name_prefix
    ActiveJob::Base.queue_name_prefix = "myapp"

    assert_equal "myapp_default", Judge::Rails::RefreshJob.new("X", 1, []).queue_name
  ensure
    ActiveJob::Base.queue_name_prefix = nil
  end

  def test_the_payload_carries_the_queue_of_the_first_attribute_that_names_one
    klass = model do
      judge_source :body
      judge_attribute :urgency, JudgeTestSupport::QUESTIONS[:urgency].call
      judge_attribute :intent, JudgeTestSupport::QUESTIONS[:intent].call, queue: :p3
      judge_attribute :frustration, JudgeTestSupport::QUESTIONS[:frustration].call, queue: "p1"
    end
    klass.create!(body: "cannot log in")

    assert_equal "p3", enqueued.last.queue
  end

  def test_the_payload_has_no_queue_when_no_attribute_names_one
    async_model.create!(body: "cannot log in")

    assert_nil enqueued.last.queue
  end

  def test_a_blank_attribute_queue_raises_at_declaration
    assert_raises(ArgumentError) do
      model { judge_attribute :urgency, JudgeTestSupport::QUESTIONS[:urgency].call, source: :body, queue: " " }
    end
  end

  def test_a_database_deadlock_is_retried_by_active_job
    assert_includes Judge::Rails::Jobs::RETRYABLE_ERRORS, ActiveRecord::Deadlocked
  end

  def test_the_enqueuer_refuses_something_that_cannot_be_called
    assert_raises(ArgumentError) { Judge::Rails::Jobs.enqueuer = nil }
  end

  def test_an_irrelevant_save_evaluates_no_async_source_after_commit
    reads = 0
    klass = model do
      judge_attribute :urgency, Judge.noul("urgent?"), source: -> { reads += 1 and body }
    end
    record = klass.create!(body: "down")
    run_payload(enqueued.shift)
    record.reload
    reads = 0

    record.update!(channel: "web")

    assert_equal 1, reads
    assert_empty enqueued
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

class JudgeRefreshJobQueueTest < JudgeRailsTest
  include ActiveJob::TestHelper

  def setup
    super
    Judge::Rails::Jobs.reset_enqueuer!
  end

  def teardown
    Judge.reset_config!
    clear_enqueued_jobs
    super
  end

  def test_an_async_save_enqueues_on_the_default_queue_when_nothing_is_set
    ticket_model.create!(body: "cannot log in")

    assert_enqueued_with(job: Judge::Rails::RefreshJob, queue: "default")
  end

  def test_an_async_save_enqueues_on_the_configured_queue
    Judge.configure { |c| c.queue = :p3 }
    ticket_model.create!(body: "cannot log in")

    assert_enqueued_with(job: Judge::Rails::RefreshJob, queue: "p3")
  end

  def test_an_attribute_queue_overrides_the_configured_one
    Judge.configure { |c| c.queue = :p3 }
    ticket_model(queue: :autopilot).create!(body: "cannot log in")

    assert_enqueued_with(job: Judge::Rails::RefreshJob, queue: "autopilot")
  end

  private

  def ticket_model(**options)
    self.class.send(:remove_const, :QueuedTicket) if self.class.const_defined?(:QueuedTicket, false)
    self.class.const_set(:QueuedTicket, model do
      judge_source :body
      judge_attribute :urgency, JudgeTestSupport::QUESTIONS[:urgency].call, **options
    end)
  end
end
