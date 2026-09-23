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
end
