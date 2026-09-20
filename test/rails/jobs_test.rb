# frozen_string_literal: true

require "rails_helper"

class JevJobsTest < JevRailsTest
  def setup
    super
    @enqueued = []
    Jev::Rails::Jobs.enqueuer = ->(payload) { @enqueued << payload }
  end

  def teardown
    Jev::Rails::Jobs.reset_enqueuer!
    super
  end

  attr_reader :enqueued

  def exploding_client(on: nil)
    JevTestSupport::RecordingClient.new do |_question, _name, state|
      raise Jev::APIError, "boom" if on.nil? || state.to_s.include?(on)

      nil
    end
  end

  def run_payload(payload, client: nil)
    Jev::Rails::Jobs.perform(payload, client: client)
  end

  def test_inline_computes_during_save
    klass = model do
      jev_source :body
      jev_attribute :urgency, JevTestSupport::QUESTIONS[:urgency].call, sync: true
    end

    record = klass.create!(body: "server is down")

    assert_in_delta 0.91, record.reload.urgency
    assert_equal 1, client.call_count
    assert_empty enqueued
  end

  def test_async_enqueues_once_per_save
    klass = async_model
    record = klass.create!(body: "cannot log in")

    assert_equal 1, enqueued.size
    payload = enqueued.first

    assert_equal :record, payload.kind
    assert_equal [record.id], payload.ids
    assert_equal %i[urgency], payload.names
    assert_equal 0, client.call_count
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
      jev_source :body
      jev_attribute :urgency, JevTestSupport::QUESTIONS[:urgency].call, callbacks: false
    end

    record = klass.create!(body: "cannot log in")
    record.update!(body: "still cannot log in")

    assert_empty enqueued
    assert_nil record.reload.urgency
  end

  def test_queue_mode_batches_ids
    klass = model do
      jev_source :body
      jev_attribute :urgency, JevTestSupport::QUESTIONS[:urgency].call, callbacks: :queue
    end

    ids = nil
    Jev::Rails::Jobs.batch do
      ids = 3.times.map { |i| klass.create!(body: "ticket #{i}").id }

      assert_empty enqueued
    end

    assert_equal 1, enqueued.size
    assert_equal :bulk, enqueued.first.kind
    assert_equal ids.sort, enqueued.first.ids.sort

    run_payload(enqueued.first)

    assert_equal 3, klass.where.not(urgency: nil).count
  end

  def test_backfill_shares_one_call_across_attributes
    klass = backfill_model
    250.times { |i| klass.create!(body: "ticket #{i}") }
    client.reset!

    summary = klass.jev_refresh_all

    assert_equal 250, summary.records
    assert_equal 250, summary.computed
    assert_equal 250, summary.calls
    assert_equal 250, client.call_count
    assert_equal 250, klass.where.not(urgency: nil).where.not(intent: nil).count
  end

  def test_backfill_counts_failures_and_continues
    klass = backfill_model
    %w[fine boom-here also-fine].each { |body| klass.create!(body: body) }
    Jev.client = exploding_client(on: "boom")

    summary = klass.jev_refresh_all

    assert_equal 3, summary.records
    assert_equal 2, summary.computed
    assert_equal 1, summary.failed
    assert_equal 2, klass.where.not(urgency: nil).count
  end

  def test_resume_skips_computed_records
    klass = backfill_model
    3.times { |i| klass.create!(body: "ticket #{i}") }
    klass.jev_refresh_all
    client.reset!

    summary = klass.jev_refresh_all(force: true, resume: true)

    assert_equal 3, summary.skipped
    assert_equal 0, summary.computed
    assert_equal 0, summary.calls
    assert_equal 0, client.call_count
  end

  def test_failed_compute_keeps_previous_value_and_does_not_raise
    klass = async_model
    record = klass.create!(body: "server is down")
    run_payload(enqueued.first)
    enqueued.clear
    record.reload

    assert_in_delta 0.91, record.urgency

    Jev.client = exploding_client
    record.update!(body: "something else entirely")

    assert_equal 1, enqueued.size
    run_payload(enqueued.first)

    record.reload

    assert_in_delta 0.91, record.urgency
    assert_predicate record, :jev_stale?
  end

  def test_inline_on_error_raise_propagates
    klass = model do
      jev_source :body
      jev_attribute :urgency, JevTestSupport::QUESTIONS[:urgency].call, sync: true, on_error: :raise
    end
    Jev.client = exploding_client

    assert_raises(Jev::APIError) { klass.create!(body: "server is down") }
  end

  def test_inline_on_error_pass_swallows
    klass = model do
      jev_source :body
      jev_attribute :urgency, JevTestSupport::QUESTIONS[:urgency].call, sync: true
    end
    Jev.client = exploding_client

    record = klass.create!(body: "server is down")

    assert_nil record.reload.urgency
  end

  def test_refresh_later_enqueues_manually
    klass = model do
      jev_source :body
      jev_attribute :urgency, JevTestSupport::QUESTIONS[:urgency].call, callbacks: false
    end
    record = klass.create!(body: "cannot log in")

    record.jev_refresh_later

    assert_equal 1, enqueued.size
    run_payload(enqueued.first)

    assert_in_delta 0.91, record.reload.urgency
  end

  private

  def async_model
    model do
      jev_source :body
      jev_attribute :urgency, JevTestSupport::QUESTIONS[:urgency].call
    end
  end

  def backfill_model
    model do
      jev_source :body
      jev_attribute :urgency, JevTestSupport::QUESTIONS[:urgency].call, callbacks: false
      jev_attribute :intent, JevTestSupport::QUESTIONS[:intent].call, callbacks: false
      jev_attribute :frustration, JevTestSupport::QUESTIONS[:frustration].call, callbacks: false
    end
  end
end
