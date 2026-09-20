# frozen_string_literal: true

require "rails_helper"

class AttributesTest < JevRailsTest
  def ticket_model
    model do
      jev_source { [subject, body] }
      jev_attribute :urgency, Jev.noul("Does this need a human within the hour?")
      jev_attribute :intent, Jev.choice("What is this about?", %w[billing technical sales])
      jev_attribute :frustration, Jev.score("How frustrated?", ["Calm", "Frustrated", "Very angry"])
    end
  end

  def ticket(klass = ticket_model)
    klass.new(subject: "Payouts failing", body: "Three days, no reply")
  end

  def test_declaration_registers_definitions
    klass = ticket_model

    assert_equal %i[urgency intent frustration], klass.jev_attributes.names
    assert_equal :urgency_jev, klass.jev_definition(:urgency).sidecar_column
    assert_equal "choice", klass.jev_definition(:intent).type
  end

  def test_attributes_sharing_a_source_cost_one_call
    t = ticket
    computed = t.jev_refresh

    assert_equal %i[urgency intent frustration], computed
    assert_equal 1, client.call_count
    assert_equal "Payouts failing\n\nThree days, no reply", client.calls.first[:state]
    assert_equal %i[urgency intent frustration], client.calls.first[:questions].keys
  end

  def test_values_are_cast_per_type
    t = ticket
    t.jev_refresh

    assert_in_delta 0.91, t.urgency
    assert_equal "billing", t.intent
    assert_in_delta 1.22, t.frustration
  end

  def test_provenance_lands_in_the_sidecar
    t = ticket
    t.jev_refresh
    meta = t.urgency_jev_meta

    assert_equal t.class.jev_definition(:urgency).digest, meta["digest"]
    assert_in_delta 0.91, meta["probability"]
    assert_equal "jev-test-1", meta["model"]
    assert_kind_of Time, t.urgency_computed_at
  end

  def test_generated_readers
    t = ticket
    t.jev_refresh

    assert_in_delta 0.91, t.urgency_probability
    assert_in_delta 0.88, t.intent_confidence
    assert_equal({ "0" => "Calm", "1" => "Frustrated", "2" => "Very angry" },
                 t.frustration_jev_meta["legend"])
  end

  def test_noul_gets_a_predicate_with_a_threshold
    t = ticket
    t.jev_refresh

    assert_predicate t, :urgency?
    assert t.urgency?(0.9)
    refute t.urgency?(0.95)
  end

  def test_only_noul_overrides_the_default_attribute_predicate
    t = ticket
    t.jev_refresh

    assert t.urgency?(0.9)
    assert_raises(ArgumentError) { t.intent?(0.9) }
    assert_raises(ArgumentError) { t.frustration?(0.9) }
  end

  def test_nothing_recomputes_when_nothing_changed
    t = ticket
    t.jev_refresh
    client.reset!

    assert_empty t.jev_refresh
    assert_equal 0, client.call_count
    refute_predicate t, :jev_stale?
  end

  def test_changing_the_source_text_invalidates_every_attribute
    t = ticket
    t.jev_refresh
    client.reset!
    t.body = "Actually never mind, all fixed"

    assert_predicate t, :jev_stale?
    assert_equal %i[urgency intent frustration], t.jev_pending
    assert_equal %i[urgency intent frustration], t.jev_refresh
    assert_equal 1, client.call_count
  end

  def test_changing_the_prompt_invalidates_only_that_attribute
    t = ticket
    t.jev_refresh
    stored = t.urgency_jev_meta
    other = model do
      jev_source { [subject, body] }
      jev_attribute :urgency, Jev.noul("Is this an emergency?")
    end
    moved = other.new(subject: t.subject, body: t.body, urgency: t.urgency, urgency_jev: stored)

    assert_predicate moved, :jev_stale?
  end

  def test_force_recomputes_a_fresh_attribute
    t = ticket
    t.jev_refresh
    client.reset!

    assert_equal %i[urgency intent frustration], t.jev_refresh(force: true)
    assert_equal 1, client.call_count
  end

  def test_a_single_attribute_can_be_refreshed_alone
    t = ticket

    assert_equal [:urgency], t.jev_refresh(:urgency)
    assert_equal [:urgency], client.calls.first[:questions].keys
    assert_nil t.intent
  end

  def test_refresh_bang_persists
    t = ticket
    t.jev_refresh!
    reloaded = t.class.find(t.id)

    assert_in_delta 0.91, reloaded.urgency
    assert_equal "billing", reloaded.intent
    assert_equal t.class.jev_definition(:urgency).digest, reloaded.urgency_jev_meta["digest"]
  end

  def test_different_sources_are_grouped_into_separate_calls
    klass = model do
      jev_attribute :urgency, Jev.noul("urgent?"), source: :body
      jev_attribute :intent, Jev.choice("what?", %w[billing technical]), source: :subject
    end
    klass.new(subject: "Refund", body: "Where is my money").jev_refresh

    assert_equal 2, client.call_count
    assert_equal ["Where is my money", "Refund"].sort, client.calls.map { |c| c[:state] }.sort
  end

  def test_blank_source_text_is_never_sent
    ticket_model.new(subject: "  ", body: nil).jev_refresh

    assert_equal 0, client.call_count
  end

  def test_if_condition_skips_an_attribute
    klass = model do
      jev_source { body }
      jev_attribute :urgency, Jev.noul("urgent?"), if_condition: ->(r) { r.channel == "chat" }
    end

    klass.new(body: "hello", channel: "email").jev_refresh

    assert_equal 0, client.call_count

    klass.new(body: "hello", channel: "chat").jev_refresh

    assert_equal 1, client.call_count
  end

  def test_decide_maps_probability_to_a_band
    t = ticket
    t.jev_refresh

    assert_equal :yes, t.jev_decide(:urgency, above: 0.9)
    assert_equal :unsure, t.jev_decide(:urgency, above: 0.95, below: 0.1)
    assert_equal :no, t.jev_decide(:urgency, above: 0.99, below: 0.95)
  end

  def test_decide_falls_back_to_the_column_for_a_noul_without_provenance
    klass = model do
      jev_source { body }
      jev_attribute :urgency, Jev.noul("urgent?")
    end

    assert_equal :yes, klass.new(body: "x", urgency: 0.95).jev_decide(:urgency, above: 0.9)
  end

  def test_decide_refuses_an_uncomputed_attribute
    assert_raises(Jev::Error) { ticket.jev_decide(:urgency, above: 0.9) }
  end

  def test_declaration_requires_a_source
    assert_raises(ArgumentError) do
      model { jev_attribute :urgency, Jev.noul("urgent?") }
    end
  end

  def test_unknown_attribute_lookup_raises
    assert_raises(ArgumentError) { ticket_model.jev_definition(:nope) }
  end

  def test_subclasses_inherit_and_extend_declarations
    parent = ticket_model
    child = Class.new(parent) do
      jev_attribute :spam, Jev.noul("Is this spam?")
    end

    assert_equal %i[urgency intent frustration], parent.jev_attributes.names
    assert_equal %i[urgency intent frustration spam], child.jev_attributes.names
  end
end
