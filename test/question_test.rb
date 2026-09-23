# frozen_string_literal: true

require "test_helper"

class QuestionTest < Minitest::Test
  def test_noul_payload
    q = Judge.noul("Does this convey urgency?", { true: "time-sensitive", false: "no urgency" },
                   name: :is_urgent)

    assert_equal "noul", q.type
    assert_equal :is_urgent, q.name
    assert_equal(
      { "type" => "noul", "instructions" => "Does this convey urgency?",
        "criteria" => { "true" => "time-sensitive", "false" => "no urgency" } },
      q.to_payload
    )
  end

  def test_noul_without_criteria_omits_the_key
    refute_includes Judge.noul("urgent?").to_payload, "criteria"
  end

  def test_choice_from_array_and_hash
    from_array = Judge.choice("which team?", %w[billing technical])
    from_hash = Judge.choice("which team?", { billing: "money", technical: "bugs" })

    assert_equal %w[billing technical], from_array.options
    assert_equal({ "billing" => "billing", "technical" => "technical" }, from_array.criteria)
    assert_equal({ "billing" => "money", "technical" => "bugs" }, from_hash.criteria)
  end

  def test_criteria_entries_can_be_structured
    choice = Judge.choice("which team?", {
                            billing: { what: "Charges", not_for: "Bugs", examples: ["Charged twice"] },
                            technical: "bugs"
                          })
    noul = Judge.noul("urgent?", { true: { what: "Money is stuck", examples: ["Refund me now"] },
                                   false: "can wait" })

    assert_equal({ "what" => "Charges", "not_for" => "Bugs", "examples" => ["Charged twice"] },
                 choice.to_payload["criteria"]["billing"])
    assert_equal({ "what" => "Money is stuck", "examples" => ["Refund me now"] }, noul.criteria["true"])
    assert_equal %w[billing technical], choice.options
    assert_predicate choice.criteria["billing"], :frozen?
  end

  def test_structured_criteria_change_the_digest_and_strings_keep_theirs
    plain = Judge.noul("urgent?", { true: "stuck", false: "wait" })
    structured = Judge.noul("urgent?", { true: { what: "stuck" }, false: "wait" })

    refute_equal plain.digest, structured.digest
    assert_equal Judge.noul("urgent?", { "true" => "stuck", "false" => "wait" }).digest, plain.digest
  end

  def test_score_accepts_a_range_or_an_array
    assert_equal %w[1 2 3 4 5], Judge.score("how urgent", 1..5).levels
    assert_equal 2, Judge.score("how frustrated", ["Calm", "Frustrated", "Very angry"]).max_level
  end

  def test_rejects_degenerate_criteria
    assert_raises(ArgumentError) { Judge.choice("pick", %w[only]) }
    assert_raises(ArgumentError) { Judge.score("rate", [1]) }
    assert_raises(ArgumentError) { Judge.noul("") }
    assert_raises(ArgumentError) { Judge.noul("urgent?", %w[not a hash]) }
  end

  def test_digest_is_stable_and_prompt_sensitive
    a = Judge.noul("Does this convey urgency?")
    b = Judge.noul("Does this convey urgency?", name: :other)
    c = Judge.noul("Does this convey URGENCY?")

    assert_equal a.digest, b.digest
    refute_equal a.digest, c.digest
    assert_equal 16, a.digest.length
  end

  def test_with_name_returns_a_named_copy
    q = Judge.noul("urgent?")
    named = q.with_name(:urgency)

    assert_nil q.name
    assert_equal :urgency, named.name
    assert_equal q.digest, named.digest
    assert_same named, named.with_name(:urgency)
  end

  def test_questions_are_frozen_and_comparable
    q = Judge.noul("urgent?", name: :a)

    assert_predicate q, :frozen?
    assert_equal Judge.noul("urgent?", name: :a), q
  end

  def test_criteria_strings_cannot_be_changed_after_the_digest
    text = +"stuck"
    question = Judge.noul("urgent?", { true: { what: text }, false: "wait" })
    text << " forever"

    assert_equal "stuck", question.criteria["true"]["what"]
    assert_predicate question.instructions, :frozen?
  end

  def test_nested_numbers_and_booleans_keep_their_json_type
    question = Judge.choice("team?", { billing: { what: "Charges", weight: 0.5, strict: true, not_for: nil },
                                       technical: "Bugs" })

    assert_equal({ "what" => "Charges", "weight" => 0.5, "strict" => true }, question.criteria["billing"])
  end

  def test_keys_that_collapse_to_one_string_are_rejected
    assert_raises(ArgumentError) do
      Judge.choice("team?", { billing: { what: "a", "what" => "b" }, technical: "c" })
    end
  end

  def test_shape_errors_are_raised_at_construction
    assert_raises(ArgumentError) { Judge.noul("urgent?", { yes: "a", no: "b" }) }
    assert_raises(ArgumentError) { Judge.choice("team?", %w[a a]) }
    assert_raises(ArgumentError) { Judge.score("how?", [{ what: "calm" }, { what: "angry" }]) }
  end
end
