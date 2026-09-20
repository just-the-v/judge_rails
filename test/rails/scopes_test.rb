# frozen_string_literal: true

require "rails_helper"

class JevScopesTest < JevRailsTest
  def setup
    super
    @klass = model do
      jev_source :body
      jev_attribute :urgency, JevTestSupport::QUESTIONS[:urgency].call
      jev_attribute :intent, JevTestSupport::QUESTIONS[:intent].call
      jev_attribute :frustration, JevTestSupport::QUESTIONS[:frustration].call
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

  def test_noul_scopes_partition_exactly_like_jev_decide
    ticket("on-upper", urgency: 0.8)
    ticket("on-lower", urgency: 0.2)
    ticket("middle", urgency: 0.5)

    assert_equal ["on-upper"], subjects(klass.urgency_above(0.8))
    assert_equal ["on-lower"], subjects(klass.urgency_below(0.2))
    assert_equal ["middle"], subjects(klass.urgency_between(0.2, 0.8))

    klass.where.not(urgency: nil).find_each do |record|
      band = record.jev_decide(:urgency, above: 0.8, below: 0.2)
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

    assert_equal ["full"], subjects(klass.jev_computed)
    assert_equal %w[blank partial], subjects(klass.jev_uncomputed)
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
    assert_raises(NoMethodError) { model.jev_computed }
  end

  def test_jev_filter_returns_matching_records
    refund_client!
    ticket("refund", body: "please send a refund")
    ticket("thanks", body: "just saying thanks")

    matched = klass.jev_filter("mentions a refund", limit: 10)

    assert_equal ["refund"], matched.map(&:subject)
    assert_equal 2, client.call_count
  end

  def test_jev_filter_honours_threshold
    refund_client!
    ticket("refund", body: "please send a refund")

    assert_equal 1, klass.jev_filter("mentions a refund", limit: 10).size
    assert_empty klass.jev_filter("mentions a refund", limit: 10, threshold: 0.95)
  end

  def test_jev_filter_respects_relation_scoping
    refund_client!
    ticket("chat", channel: "chat", body: "chat refund please")
    ticket("mail", channel: "email", body: "mail refund please")

    matched = klass.where(channel: "chat").jev_filter("mentions a refund", limit: 10)

    assert_equal ["chat"], matched.map(&:subject)
    assert_equal(["chat refund please"], client.calls.map { |c| c[:state] })
  end

  def test_jev_filter_enforces_the_limit
    refund_client!
    5.times { |i| ticket("t#{i}", body: "refund #{i}") }

    matched = klass.jev_filter("mentions a refund", limit: 2)

    assert_equal 2, client.call_count
    assert_equal 2, matched.size
  end

  def test_ad_hoc_helpers_require_a_limit
    %i[jev_filter jev_map jev_sort].each do |name|
      error = assert_raises(ArgumentError) { klass.public_send(name, "is this urgent?") }
      assert_match(/limit:/, error.message)
      assert_match(/API call per row/, error.message)
    end
    assert_raises(ArgumentError) { klass.jev_filter("x", limit: 0) }
    assert_equal 0, client.call_count
  end

  def test_ad_hoc_helpers_need_a_source
    plain = model
    error = assert_raises(ArgumentError) { plain.jev_map("is this urgent?", limit: 5) }
    assert_match(/source:/, error.message)
  end

  def test_ad_hoc_source_can_be_a_callable
    plain = model
    plain.create!(subject: "a", body: "b")

    plain.jev_map("is this urgent?", limit: 5, source: ->(record) { "#{record.subject}!" })

    assert_equal(["a!"], client.calls.map { |c| c[:state] })
  end

  def test_jev_map_returns_results_keyed_by_record
    record = ticket("one")

    mapped = klass.jev_map("is this urgent?", limit: 5)

    assert_equal [record], mapped.keys
    assert_kind_of Jev::Result, mapped[record]
    assert_in_delta 0.91, mapped[record].value
  end

  def test_a_string_question_is_coerced_to_a_noul
    ticket("one")

    klass.jev_map("is this urgent?", limit: 5)

    question = client.calls.first[:questions].values.first
    assert_equal "noul", question.type
    assert_equal "is this urgent?", question.instructions
  end

  def test_a_question_object_is_used_as_is
    ticket("one")

    klass.jev_map(Jev.choice("what is this?", %w[billing technical sales]), limit: 5)

    assert_equal "choice", client.calls.first[:questions].values.first.type
  end

  def test_jev_sort_orders_by_judgement
    scoring_client!
    ticket("low", body: "score 1")
    ticket("high", body: "score 9")
    ticket("mid", body: "score 5")

    assert_equal %w[high mid low], klass.jev_sort("churn risk?", limit: 10).map(&:subject)
    assert_equal %w[low mid high], klass.jev_sort("churn risk?", limit: 10, dir: :asc).map(&:subject)
  end

  private

  def refund_client!
    install_client { |_q, _name, state| noul_answer(state.include?("refund") ? 0.9 : 0.1) }
  end

  def scoring_client!
    install_client { |_q, _name, state| noul_answer(state[/score (\d)/, 1].to_f / 10) }
  end

  def install_client(&)
    @client = JevTestSupport::RecordingClient.new(&)
    Jev.client = @client
  end

  def noul_answer(value)
    { "type" => "noul", "noul" => value }
  end
end
