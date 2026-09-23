# frozen_string_literal: true

require "rails_helper"

class AttributesTest < JudgeRailsTest
  def ticket_model
    model do
      judge_source { [subject, body] }
      judge_attribute :urgency, Judge.noul("Does this need a human within the hour?")
      judge_attribute :intent, Judge.choice("What is this about?", %w[billing technical sales])
      judge_attribute :frustration, Judge.score("How frustrated?", ["Calm", "Frustrated", "Very angry"])
    end
  end

  def ticket(klass = ticket_model)
    klass.new(subject: "Payouts failing", body: "Three days, no reply")
  end

  def test_declaration_registers_definitions
    klass = ticket_model

    assert_equal %i[urgency intent frustration], klass.judge_attributes.names
    assert_equal :urgency_judge, klass.judge_definition(:urgency).sidecar_column
    assert_equal "choice", klass.judge_definition(:intent).type
  end

  def test_attributes_sharing_a_source_cost_one_call
    t = ticket
    computed = t.judge_refresh

    assert_equal %i[urgency intent frustration], computed
    assert_equal 1, adapter.call_count
    assert_equal "Payouts failing\n\nThree days, no reply", adapter.calls.first[:state]
    assert_equal %i[urgency intent frustration], adapter.calls.first[:questions].keys
  end

  def test_values_are_cast_per_type
    t = ticket
    t.judge_refresh

    assert_in_delta 0.91, t.urgency
    assert_equal "billing", t.intent
    assert_in_delta 1.22, t.frustration
  end

  def test_provenance_lands_in_the_sidecar
    t = ticket
    t.judge_refresh
    meta = t.urgency_judge_meta

    assert_equal t.class.judge_definition(:urgency).digest, meta["digest"]
    assert_in_delta 0.91, meta["probability"]
    assert_equal "jev-test-1", meta["model"]
    assert_kind_of Time, t.urgency_computed_at
  end

  def test_generated_readers
    t = ticket
    t.judge_refresh

    assert_in_delta 0.91, t.urgency_probability
    assert_in_delta 0.88, t.intent_confidence
    assert_equal({ "0" => "Calm", "1" => "Frustrated", "2" => "Very angry" },
                 t.frustration_judge_meta["legend"])
  end

  def test_noul_gets_a_predicate_with_a_threshold
    t = ticket
    t.judge_refresh

    assert_predicate t, :urgency?
    assert t.urgency?(0.9)
    refute t.urgency?(0.95)
  end

  def test_only_noul_overrides_the_default_attribute_predicate
    t = ticket
    t.judge_refresh

    assert t.urgency?(0.9)
    assert_raises(ArgumentError) { t.intent?(0.9) }
    assert_raises(ArgumentError) { t.frustration?(0.9) }
  end

  def test_nothing_recomputes_when_nothing_changed
    t = ticket
    t.judge_refresh
    adapter.reset!

    assert_empty t.judge_refresh
    assert_equal 0, adapter.call_count
    refute_predicate t, :judge_stale?
  end

  def test_changing_the_source_text_invalidates_every_attribute
    t = ticket
    t.judge_refresh
    adapter.reset!
    t.body = "Actually never mind, all fixed"

    assert_predicate t, :judge_stale?
    assert_equal %i[urgency intent frustration], t.judge_pending
    assert_equal %i[urgency intent frustration], t.judge_refresh
    assert_equal 1, adapter.call_count
  end

  def test_changing_the_prompt_invalidates_only_that_attribute
    t = ticket
    t.judge_refresh
    stored = t.urgency_judge_meta
    other = model do
      judge_source { [subject, body] }
      judge_attribute :urgency, Judge.noul("Is this an emergency?")
    end
    moved = other.new(subject: t.subject, body: t.body, urgency: t.urgency, urgency_judge: stored)

    assert_predicate moved, :judge_stale?
  end

  def test_force_recomputes_a_fresh_attribute
    t = ticket
    t.judge_refresh
    adapter.reset!

    assert_equal %i[urgency intent frustration], t.judge_refresh(force: true)
    assert_equal 1, adapter.call_count
  end

  def test_a_single_attribute_can_be_refreshed_alone
    t = ticket

    assert_equal [:urgency], t.judge_refresh(:urgency)
    assert_equal [:urgency], adapter.calls.first[:questions].keys
    assert_nil t.intent
  end

  def test_refresh_bang_persists
    t = ticket
    t.judge_refresh!
    reloaded = t.class.find(t.id)

    assert_in_delta 0.91, reloaded.urgency
    assert_equal "billing", reloaded.intent
    assert_equal t.class.judge_definition(:urgency).digest, reloaded.urgency_judge_meta["digest"]
  end

  def test_different_sources_are_grouped_into_separate_calls
    klass = model do
      judge_attribute :urgency, Judge.noul("urgent?"), source: :body
      judge_attribute :intent, Judge.choice("what?", %w[billing technical]), source: :subject
    end
    klass.new(subject: "Refund", body: "Where is my money").judge_refresh

    assert_equal 2, adapter.call_count
    assert_equal ["Where is my money", "Refund"].sort, adapter.calls.map { |c| c[:state] }.sort
  end

  def test_blank_source_text_is_never_sent
    ticket_model.new(subject: "  ", body: nil).judge_refresh

    assert_equal 0, adapter.call_count
  end

  def test_if_condition_skips_an_attribute
    klass = model do
      judge_source { body }
      judge_attribute :urgency, Judge.noul("urgent?"), if_condition: ->(r) { r.channel == "chat" }
    end

    klass.new(body: "hello", channel: "email").judge_refresh

    assert_equal 0, adapter.call_count

    klass.new(body: "hello", channel: "chat").judge_refresh

    assert_equal 1, adapter.call_count
  end

  def test_decide_maps_probability_to_a_band
    t = ticket
    t.judge_refresh

    assert_equal :yes, t.judge_decide(:urgency, above: 0.9)
    assert_equal :unsure, t.judge_decide(:urgency, above: 0.95, below: 0.1)
    assert_equal :no, t.judge_decide(:urgency, above: 0.99, below: 0.95)
  end

  def test_decide_falls_back_to_the_column_for_a_noul_without_provenance
    klass = model do
      judge_source { body }
      judge_attribute :urgency, Judge.noul("urgent?")
    end

    assert_equal :yes, klass.new(body: "x", urgency: 0.95).judge_decide(:urgency, above: 0.9)
  end

  def test_decide_refuses_an_uncomputed_attribute
    assert_raises(Judge::Error) { ticket.judge_decide(:urgency, above: 0.9) }
  end

  def test_declaration_requires_a_source
    assert_raises(ArgumentError) do
      model { judge_attribute :urgency, Judge.noul("urgent?") }
    end
  end

  def test_unknown_attribute_lookup_raises
    assert_raises(ArgumentError) { ticket_model.judge_definition(:nope) }
  end

  def test_subclasses_inherit_and_extend_declarations
    parent = ticket_model
    child = Class.new(parent) do
      judge_attribute :spam, Judge.noul("Is this spam?")
    end

    assert_equal %i[urgency intent frustration], parent.judge_attributes.names
    assert_equal %i[urgency intent frustration spam], child.judge_attributes.names
  end

  def test_blanking_the_source_clears_the_value_and_is_not_stale
    klass = model do
      judge_source :body
      judge_attribute :urgency, Judge.noul("urgent?"), callbacks: false
    end
    record = klass.create!(body: "server down")
    record.judge_refresh!
    record.update!(body: "")

    assert_equal [:urgency], record.judge_pending
    assert_equal [:urgency], record.judge_refresh!
    record.reload

    assert_nil record.urgency
    assert_empty record.urgency_judge_meta
    refute_predicate record, :judge_stale?
    assert_empty record.judge_pending
    assert_equal 1, adapter.call_count
  end

  def test_a_zero_arity_if_condition_runs_against_the_record
    klass = model do
      judge_source :body
      judge_attribute :urgency, Judge.noul("urgent?"), sync: true, if_condition: -> { channel == "web" }
    end

    klass.create!(body: "x", channel: "email")
    klass.create!(body: "x", channel: "web")

    assert_equal 1, adapter.call_count
  end

  def test_an_attribute_level_model_is_sent_and_grouped_separately
    klass = model do
      judge_source :body
      judge_attribute :urgency, Judge.noul("urgent?"), model: "jev-pinned-9", callbacks: false
      judge_attribute :intent, Judge.choice("What is it?", %w[billing technical]), callbacks: false
    end

    klass.new(body: "charged twice").judge_refresh

    assert_equal %w[jev-latest jev-pinned-9], adapter.calls.map { |c| c[:model] }.sort
  end

  def test_changing_the_pinned_model_makes_the_value_stale
    question = Judge.noul("urgent?")
    pinned = lambda do |name|
      model { judge_attribute :urgency, question, source: :body, model: name, callbacks: false }
    end
    record = pinned.call("jev-1.13.0").create!(body: "down")
    record.judge_refresh!

    bumped = pinned.call("jev-1.14.0").find(record.id)

    assert_predicate bumped, :judge_stale?
    refute_predicate pinned.call("jev-1.13.0").find(record.id), :judge_stale?
  end

  def test_refresh_reads_each_source_once
    reads = 0
    klass = model do
      judge_attribute :urgency, Judge.noul("urgent?"), source: -> { reads += 1 and body }, callbacks: false
    end
    record = klass.new(body: "down")
    reads = 0
    record.judge_refresh

    assert_equal 1, reads
  end

  def test_no_model_and_the_default_model_share_one_call
    klass = model do
      judge_source :body
      judge_attribute :urgency, Judge.noul("urgent?"), callbacks: false
      judge_attribute :intent, Judge.choice("What is it?", %w[billing technical]), model: "jev-latest",
                                                                                   callbacks: false
    end

    klass.new(body: "charged twice").judge_refresh

    assert_equal(["jev-latest"], adapter.calls.map { |c| c[:model] })
  end

  def test_changing_the_configured_model_makes_unpinned_values_stale
    klass = model { judge_attribute :urgency, Judge.noul("urgent?"), source: :body, callbacks: false }
    record = klass.create!(body: "down")
    record.judge_refresh!
    Judge.config.model = "jev-2"

    assert_predicate record, :judge_stale?
  ensure
    Judge.config.model = Judge::Configuration::DEFAULT_MODEL
  end

  def test_saving_a_partially_selected_record_skips_judgments_it_cannot_read
    klass = model do
      judge_source { [subject, body] }
      judge_attribute :urgency, Judge.noul("urgent?"), sync: true
    end
    klass.create!(subject: "s", body: "b")
    adapter.reset!

    klass.select(:id, :channel).find_each { |ticket| ticket.update!(channel: "web") }

    assert_equal 0, adapter.call_count
  end

  def test_a_failure_part_way_keeps_the_judgments_already_paid_for
    klass = model do
      judge_attribute :urgency, Judge.noul("urgent?"), source: :subject, callbacks: false
      judge_attribute :intent, Judge.choice("What is it?", %w[billing technical]), source: :body,
                                                                                   callbacks: false
    end
    record = klass.create!(subject: "subject", body: "body")
    Judge.adapter = JudgeTestSupport::RecordingClient.new do |_question, _name, state|
      raise Judge::ServerError, "503" if state == "body"
    end

    assert_raises(Judge::ServerError) { record.judge_refresh! }
    assert_in_delta 0.91, klass.find(record.id).urgency
  end

  def test_computed_at_accepts_an_already_parsed_time
    record = ticket_model.new(urgency: 0.5, urgency_judge: { "computed_at" => Time.utc(2026, 1, 1) })

    assert_equal Time.utc(2026, 1, 1), record.urgency_computed_at
  end

  def test_declaration_errors_surface_at_load_time
    assert_raises(ArgumentError) { model { judge_attribute :urgency, Judge.noul("urgent?"), source: 42 } }
    assert_raises(ArgumentError) do
      model { judge_attribute :urgency, Judge.noul("urgent?"), source: :body, sync: true, callbacks: :async }
    end
    assert_predicate model { judge_attribute :urgency, Judge.noul("u?"), source: :body, callbacks: true }
      .judge_definition(:urgency), :enqueue?
  end

  def test_sti_rows_are_backfilled_with_their_own_definitions
    base = model do
      define_singleton_method(:name) { "BaseTicket" }
      self.inheritance_column = :channel
      judge_attribute :urgency, Judge.noul("urgent?"), source: :body, callbacks: false
    end
    vip = Class.new(base) do
      define_singleton_method(:name) { "VipTicket" }
      judge_attribute :intent, Judge.choice("What is it?", %w[billing technical]), source: :body,
                                                                                   callbacks: false
    end
    Object.const_set(:BaseTicket, base)
    Object.const_set(:VipTicket, vip)
    record = vip.create!(body: "charged twice")

    base.judge_refresh_all

    assert_equal "billing", vip.find(record.id).intent
  ensure
    Object.send(:remove_const, :VipTicket) if Object.const_defined?(:VipTicket)
    Object.send(:remove_const, :BaseTicket) if Object.const_defined?(:BaseTicket)
  end

  def test_an_attribute_without_its_columns_fails_loudly
    klass = model { judge_attribute :spam, Judge.noul("spam?"), source: :body, callbacks: false }

    assert_raises(ActiveModel::MissingAttributeError) { klass.new(body: "x").judge_refresh }
  end
end
