# frozen_string_literal: true

require "rails_helper"

class JudgeScopesTest < JudgeRailsTest
  def setup
    super
    @klass = model do
      judge_source :body
      judge_attribute :urgency, JudgeTestSupport::QUESTIONS[:urgency].call
      judge_attribute :intent, JudgeTestSupport::QUESTIONS[:intent].call
      judge_attribute :frustration, JudgeTestSupport::QUESTIONS[:frustration].call
    end
  end

  attr_reader :klass

  def ticket(subject, **attrs)
    klass.create!({ subject: subject, body: "body of #{subject}", channel: "email" }.merge(attrs))
  end

  def subjects(relation)
    relation.pluck(:subject).sort
  end

  def count_queries
    queries = 0
    subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |_n, _s, _f, _i, payload|
      unless payload[:name] == "SCHEMA" || payload[:sql].match?(/\A\s*(BEGIN|COMMIT|RELEASE|SAVEPOINT)/i)
        queries += 1
      end
    end
    yield
    queries
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription)
  end

  def test_noul_scopes
    ticket("hot", urgency: 0.9)
    ticket("mild", urgency: 0.4)
    ticket("blank")

    assert_equal ["hot"], subjects(klass.urgency_above(0.5))
    assert_equal ["mild"], subjects(klass.urgency_below(0.5))
    assert_equal %w[hot mild], subjects(klass.urgency_between(0.3, 0.95))
    assert_equal ["blank"], subjects(klass.urgency_unknown)
  end

  def test_noul_scopes_partition_exactly_like_judge_decide
    ticket("on-upper", urgency: 0.8)
    ticket("on-lower", urgency: 0.2)
    ticket("middle", urgency: 0.5)

    assert_equal ["on-upper"], subjects(klass.urgency_above(0.8))
    assert_equal ["on-lower"], subjects(klass.urgency_below(0.2))
    assert_equal ["middle"], subjects(klass.urgency_between(0.2, 0.8))

    klass.where.not(urgency: nil).find_each do |record|
      band = record.judge_decide(:urgency, above: 0.8, below: 0.2)
      scope = { yes: klass.urgency_above(0.8), no: klass.urgency_below(0.2),
                unsure: klass.urgency_between(0.2, 0.8) }.fetch(band)

      assert_includes subjects(scope), record.subject,
                      "#{record.subject} (#{record.urgency}) landed in #{band}"
    end
  end

  def test_choice_scopes
    ticket("bill", intent: "billing")
    ticket("tech", intent: "technical")
    ticket("blank")

    assert_equal ["bill"], subjects(klass.intent_is("billing"))
    assert_equal %w[bill tech], subjects(klass.intent_is("billing", "technical"))
    assert_equal ["tech"], subjects(klass.intent_not("billing"))
    assert_equal ["blank"], subjects(klass.intent_unknown)
  end

  def test_choice_scope_rejects_an_unknown_option
    error = assert_raises(ArgumentError) { klass.intent_is("refunds") }
    assert_match(/refunds/, error.message)
    assert_match(/billing/, error.message)

    assert_raises(ArgumentError) { klass.intent_not("refunds") }
    assert_raises(ArgumentError) { klass.intent_is }
  end

  def test_score_scopes
    ticket("calm", frustration: 0.2)
    ticket("cross", frustration: 1.22)
    ticket("furious", frustration: 1.9)
    ticket("blank")

    assert_equal %w[cross furious], subjects(klass.frustration_at_least("Frustrated"))
    assert_equal %w[calm cross], subjects(klass.frustration_at_most("Frustrated"))
    assert_equal ["cross"], subjects(klass.frustration_level(1))
    assert_equal ["furious"], subjects(klass.frustration_level("Very angry"))
    assert_equal ["blank"], subjects(klass.frustration_unknown)
    assert_equal %w[cross furious], subjects(klass.frustration_at_least(1))
  end

  def test_score_scope_rejects_an_unknown_level
    error = assert_raises(ArgumentError) { klass.frustration_at_least("Livid") }
    assert_match(/Livid/, error.message)
    assert_raises(ArgumentError) { klass.frustration_level(7) }
  end

  def test_order_by_works_both_ways
    ticket("low", urgency: 0.1)
    ticket("high", urgency: 0.9)

    assert_equal %w[high low], klass.order_by_urgency.pluck(:subject)
    assert_equal %w[low high], klass.order_by_urgency(:asc).pluck(:subject)
    assert_raises(ArgumentError) { klass.order_by_urgency(:sideways) }
  end

  def test_model_wide_computed_scopes
    ticket("full", urgency: 0.9, intent: "billing", frustration: 1.0)
    ticket("partial", urgency: 0.9)
    ticket("blank")

    assert_equal ["full"], subjects(klass.judge_computed)
    assert_equal %w[blank partial], subjects(klass.judge_uncomputed)
  end

  def test_scopes_compose_into_one_query
    ticket("keep", urgency: 0.9, intent: "billing", frustration: 1.9)
    ticket("drop", urgency: 0.1, intent: "technical", frustration: 0.1)

    relation = klass.urgency_above(0.5).intent_is("billing").frustration_at_least("Frustrated")
    relation.to_a

    composed = klass.urgency_above(0.5).intent_is("billing").order_by_frustration(:desc).limit(10)
    assert_equal(1, count_queries { composed.to_a })
    assert_equal ["keep"], composed.pluck(:subject)

    sql = composed.to_sql
    assert_equal 1, sql.scan(/SELECT/i).size
    assert_match(/ORDER BY/i, sql)
  end

  def test_scopes_chain_from_a_relation_and_stay_relations
    ticket("chat", channel: "chat", urgency: 0.9)
    ticket("mail", channel: "email", urgency: 0.9)

    relation = klass.where(channel: "chat").urgency_above(0.5)
    assert_kind_of ActiveRecord::Relation, relation
    assert_equal ["chat"], relation.pluck(:subject)
    assert_equal 1, relation.count
  end

  def test_undeclared_scopes_still_raise
    assert_raises(NoMethodError) { klass.urgency_sideways(1) }
    assert_raises(NoMethodError) { model.judge_computed }
  end

  def test_judge_filter_returns_matching_records
    refund_client!
    ticket("refund", body: "please send a refund")
    ticket("thanks", body: "just saying thanks")

    matched = klass.judge_filter("mentions a refund", limit: 10)

    assert_equal ["refund"], matched.map(&:subject)
    assert_equal 2, adapter.call_count
  end

  def test_judge_filter_fans_out_over_threads_and_keeps_every_record
    refund_client!
    40.times { |i| ticket("refund #{i}", body: "please send a refund #{i}") }

    matched = klass.judge_filter("mentions a refund", limit: 40)

    assert_equal 40, matched.size
    assert_equal 40, adapter.call_count
    assert_equal 40, matched.map(&:id).uniq.size
  end

  def test_judge_filter_sends_one_subject_per_request
    refund_client!
    3.times { |i| ticket("refund #{i}", body: "body #{i}") }

    klass.judge_filter("mentions a refund", limit: 3)

    assert_equal 3, adapter.calls.size
    adapter.calls.each { |call| assert_equal 1, call[:questions].size }
    assert_equal ["body 0", "body 1", "body 2"].sort,
                 adapter.calls.map { |call| call[:state] }.sort
  end

  def test_judge_filter_runs_inline_when_concurrency_is_one
    refund_client!
    2.times { |i| ticket("refund #{i}", body: "refund #{i}") }

    assert_equal 2, klass.judge_filter("mentions a refund", limit: 2, concurrency: 1).size
  end

  def test_judge_sort_keeps_its_order_through_the_pool
    install_client { |_q, _name, state| noul_answer(state.include?("high") ? 0.9 : 0.1) }
    ticket("low", body: "low")
    ticket("high", body: "high")

    assert_equal %w[high low], klass.judge_sort("is it urgent", limit: 2).map(&:subject)
  end

  def test_judge_filter_honours_threshold
    refund_client!
    ticket("refund", body: "please send a refund")

    assert_equal 1, klass.judge_filter("mentions a refund", limit: 10).size
    assert_empty klass.judge_filter("mentions a refund", limit: 10, threshold: 0.95)
  end

  def test_judge_filter_respects_relation_scoping
    refund_client!
    ticket("chat", channel: "chat", body: "chat refund please")
    ticket("mail", channel: "email", body: "mail refund please")

    matched = klass.where(channel: "chat").judge_filter("mentions a refund", limit: 10)

    assert_equal ["chat"], matched.map(&:subject)
    assert_equal(["chat refund please"], adapter.calls.map { |c| c[:state] })
  end

  def test_judge_filter_enforces_the_limit
    refund_client!
    5.times { |i| ticket("t#{i}", body: "refund #{i}") }

    matched = klass.judge_filter("mentions a refund", limit: 2)

    assert_equal 2, adapter.call_count
    assert_equal 2, matched.size
  end

  def test_ad_hoc_helpers_require_a_limit
    %i[judge_filter judge_map judge_sort].each do |name|
      error = assert_raises(ArgumentError) { klass.public_send(name, "is this urgent?") }
      assert_match(/limit:/, error.message)
      assert_match(/API call per row/, error.message)
    end
    assert_raises(ArgumentError) { klass.judge_filter("x", limit: 0) }
    assert_equal 0, adapter.call_count
  end

  def test_ad_hoc_helpers_need_a_source
    plain = model
    error = assert_raises(ArgumentError) { plain.judge_map("is this urgent?", limit: 5) }
    assert_match(/source:/, error.message)
  end

  def test_ad_hoc_source_can_be_a_callable
    plain = model
    plain.create!(subject: "a", body: "b")

    plain.judge_map("is this urgent?", limit: 5, source: ->(record) { "#{record.subject}!" })

    assert_equal(["a!"], adapter.calls.map { |c| c[:state] })
  end

  def test_judge_map_returns_results_keyed_by_record
    record = ticket("one")

    mapped = klass.judge_map("is this urgent?", limit: 5)

    assert_equal [record], mapped.keys
    assert_kind_of Judge::Result, mapped[record]
    assert_in_delta 0.91, mapped[record].value
  end

  def test_a_string_question_is_coerced_to_a_noul
    ticket("one")

    klass.judge_map("is this urgent?", limit: 5)

    question = adapter.calls.first[:questions].values.first
    assert_equal "noul", question.type
    assert_equal "is this urgent?", question.instructions
  end

  def test_a_question_object_is_used_as_is
    ticket("one")

    klass.judge_map(Judge.choice("what is this?", %w[billing technical sales]), limit: 5)

    assert_equal "choice", adapter.calls.first[:questions].values.first.type
  end

  def test_judge_sort_orders_by_judgement
    scoring_client!
    ticket("low", body: "score 1")
    ticket("high", body: "score 9")
    ticket("mid", body: "score 5")

    assert_equal %w[high mid low], klass.judge_sort("churn risk?", limit: 10).map(&:subject)
    assert_equal %w[low mid high], klass.judge_sort("churn risk?", limit: 10, dir: :asc).map(&:subject)
  end

  def test_an_integer_names_the_level_when_levels_are_numeric
    numeric = model do
      judge_source :body
      judge_attribute :frustration, Judge.score("How severe?", 1..5)
    end
    numeric.create!(subject: "three", body: "b", frustration: 2.0)
    numeric.create!(subject: "four", body: "b", frustration: 3.0)
    numeric.create!(subject: "five", body: "b", frustration: 4.0)

    assert_equal %w[five four], subjects(numeric.frustration_at_least(4))
    assert_equal %w[four three], subjects(numeric.frustration_at_most(4))
    assert_equal ["four"], subjects(numeric.frustration_level(4))
    assert_raises(ArgumentError) { numeric.frustration_at_least(0) }
  end

  def test_judge_filter_never_raises_a_limit_the_relation_already_set
    refund_client!
    5.times { |i| ticket("t#{i}", body: "refund #{i}") }

    klass.limit(2).judge_filter("mentions a refund", limit: 25)

    assert_equal 2, adapter.call_count
  end

  def test_judge_filter_skips_records_with_blank_text
    refund_client!
    ticket("empty", body: "")
    ticket("full", body: "refund please")

    matched = klass.judge_filter("mentions a refund", limit: 10, source: :body)

    assert_equal ["full"], matched.map(&:subject)
    assert_equal(["refund please"], adapter.calls.map { |c| c[:state] })
  end

  def test_a_choice_filter_needs_an_option_and_uses_its_probability
    ticket("billing", body: "charged twice")
    question = Judge.choice("What is it?", %w[billing technical sales])

    assert_raises(ArgumentError) { klass.judge_filter(question, limit: 5) }
    assert_equal 0, adapter.call_count
    assert_equal ["billing"], klass.judge_filter(question, option: "billing", limit: 5).map(&:subject)
    assert_empty klass.judge_filter(question, option: "technical", limit: 5)
  end

  def test_a_score_filter_needs_a_level
    ticket("cross", body: "annoyed")
    question = Judge.score("How frustrated?", ["Calm", "Frustrated", "Very angry"])

    assert_raises(ArgumentError) { klass.judge_filter(question, limit: 5) }
    assert_equal ["cross"], klass.judge_filter(question, at_least: "Frustrated", limit: 5).map(&:subject)
    assert_empty klass.judge_filter(question, at_least: "Very angry", limit: 5)
  end

  def test_identical_texts_are_asked_once
    3.times { |i| ticket("t#{i}", body: "same text") }

    klass.judge_map("mentions a refund", limit: 10, source: :body)

    assert_equal 1, adapter.call_count
  end

  def test_a_bad_threshold_is_rejected_before_any_call
    ticket("t", body: "x")

    assert_raises(ArgumentError) { klass.judge_filter("refund?", limit: 5, threshold: 5) }
    assert_equal 0, adapter.call_count
  end

  def test_noul_scopes_reject_a_value_that_is_not_a_probability
    assert_raises(ArgumentError) { klass.urgency_above("high") }
  end

  def test_scopes_exist_as_soon_as_the_attribute_is_declared
    fresh = model { judge_attribute :urgency, Judge.noul("urgent?"), source: :body }

    assert fresh.singleton_class.method_defined?(:urgency_above)
    assert_respond_to fresh, :judge_computed
  end

  def test_a_hand_written_scope_keeps_its_name
    custom = model do
      scope :urgency_above, ->(_value) { where(channel: "custom") }
      judge_attribute :urgency, Judge.noul("urgent?"), source: :body
    end
    custom.create!(body: "x", channel: "custom", urgency: 0.1)

    assert_equal 1, custom.urgency_above(0.9).count
  end

  def test_an_sti_subclass_gets_scopes_for_its_own_questions
    base = model { judge_attribute :intent, Judge.choice("What?", %w[billing technical]), source: :body }
    sub = Class.new(base) { judge_attribute :intent, Judge.choice("What?", %w[sales spam]), source: :body }

    assert_raises(ArgumentError) { sub.intent_is("billing") }
    assert sub.intent_is("sales")
  end

  private

  def refund_client!
    install_client { |_q, _name, state| noul_answer(state.include?("refund") ? 0.9 : 0.1) }
  end

  def scoring_client!
    install_client { |_q, _name, state| noul_answer(state[/score (\d)/, 1].to_f / 10) }
  end

  def install_client(&)
    @adapter = JudgeTestSupport::RecordingClient.new(&)
    Judge.adapter = @adapter
  end

  def noul_answer(value)
    { "type" => "noul", "noul" => value }
  end
end
