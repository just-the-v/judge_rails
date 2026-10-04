# frozen_string_literal: true

require "rails_helper"

class DefinitionTest < JudgeRailsTest
  def define(**)
    Judge::Rails::Definition.new(
      name: :urgency, question: Judge.noul("Does this need a human within the hour?"),
      source: :body, **
    )
  end

  def record(body: "payouts failing for 3 days")
    model.new(body: body)
  end

  def test_columns_are_derived_from_the_name
    d = define

    assert_equal :urgency, d.value_column
    assert_equal :urgency_judge, d.sidecar_column
    assert_equal "noul", d.type
  end

  def test_question_is_renamed_to_the_attribute
    assert_equal :urgency, define.question.name
  end

  def test_source_accepts_a_symbol_or_a_callable
    assert_equal "abc", define.state_for(record(body: "abc"))

    joined = Judge::Rails::Definition.new(
      name: :urgency, question: Judge.noul("urgent?"),
      source: ->(r) { [r.subject, r.body] }
    )
    r = model.new(subject: "S", body: "B")

    assert_equal "S\n\nB", joined.state_for(r)
  end

  def test_blank_source_parts_are_dropped
    joined = Judge::Rails::Definition.new(name: :urgency, question: Judge.noul("urgent?"),
                                          source: ->(r) { [r.subject, r.body] })

    assert_equal "B", joined.state_for(model.new(subject: "  ", body: "B"))
  end

  def test_callbacks_default_to_async_and_sync_switches_to_inline
    assert_equal :async, define.callbacks
    refute_predicate define, :sync?
    assert_predicate define(sync: true), :sync?
    assert_equal :disabled, define(callbacks: false).callbacks
    refute_predicate define(callbacks: false), :enqueue?
  end

  def test_invalid_options_are_rejected_at_declaration_time
    assert_raises(ArgumentError) { define(callbacks: :later) }
    assert_raises(ArgumentError) { define(on_error: :explode) }
  end

  def test_applies_to_honours_the_if_condition
    always = define
    never = define(if_condition: ->(_r) { false })

    assert always.applies_to?(record)
    refute never.applies_to?(record)
  end

  def test_stale_when_value_missing
    d = define

    assert d.stale?(value: nil, sidecar: {}, state: "x")
  end

  def test_stale_when_the_prompt_changed
    d = define
    fresh = { "digest" => d.digest, "state_digest" => d.state_digest("x") }

    refute d.stale?(value: 0.9, sidecar: fresh, state: "x")
    assert d.stale?(value: 0.9, sidecar: fresh.merge("digest" => "other"), state: "x")
  end

  def test_switching_to_clef_makes_jev_judgments_stale
    Judge.reset_config!
    Judge.adapter = adapter
    d = define
    jev = { "digest" => d.digest, "state_digest" => d.state_digest("x") }
    Judge.config.adapter = :clef

    assert_equal "clef", d.effective_model
    assert d.stale?(value: 0.9, sidecar: jev, state: "x")
  ensure
    Judge.reset_config!
    Judge.adapter = adapter
  end

  def test_stale_when_the_source_text_changed
    d = define
    sidecar = { "digest" => d.digest, "state_digest" => d.state_digest("x") }

    assert d.stale?(value: 0.9, sidecar: sidecar, state: "y")
  end

  def test_cast_per_question_type
    noul = define
    choice = Judge::Rails::Definition.new(name: :intent, source: :body,
                                          question: Judge.choice("what?", %w[billing technical]))
    score = Judge::Rails::Definition.new(name: :frustration,
                                         question: Judge.score("how?", %w[calm cross angry]), source: :body)
    set = adapter.call(state: "x", questions: { urgency: noul.question, intent: choice.question,
                                                frustration: score.question })

    assert_in_delta 0.91, noul.cast(set[:urgency])
    assert_equal "billing", choice.cast(set[:intent])
    assert_in_delta 1.22, score.cast(set[:frustration])
  end

  def test_sidecar_captures_provenance
    d = define
    set = adapter.call(state: "x", questions: { urgency: d.question })
    meta = d.sidecar(set[:urgency], state_digest: d.state_digest("x"), model: "jev-test-1", latency: 0.01)

    assert_equal d.digest, meta["digest"]
    assert_equal d.state_digest("x"), meta["state_digest"]
    assert_in_delta 0.91, meta["probability"]
    assert_equal "jev-test-1", meta["model"]
    refute_nil meta["computed_at"]
  end

  def test_registry_lookup_and_inheritance
    parent = Judge::Rails::Registry.new
    parent.add(define)
    child = parent.inherit
    child.add(Judge::Rails::Definition.new(name: :intent, question: Judge.choice("what?", %w[a b]),
                                           source: :body))

    assert_equal %i[urgency], parent.names
    assert_equal %i[urgency intent], child.names
    assert_equal :urgency, child[:urgency].name
    assert_raises(ArgumentError) { parent.fetch(:intent) }
  end
end
