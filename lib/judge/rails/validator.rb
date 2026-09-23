# frozen_string_literal: true

I18n.load_path << File.expand_path("locale/en.yml", __dir__)

module Judge
  module Rails
    module Validator
      extend ActiveSupport::Concern

      def judge_validation_results
        @judge_validation_results ||= {}
      end

      def judge_judgment(text, instruction)
        @judge_judgments && @judge_judgments[[text, instruction]]
      end

      def judge_store_judgment(text, instruction, outcome)
        @judge_judgments ||= {}
        @judge_judgments[[text, instruction]] = outcome
      end

      def judge_record_validation_result(attribute, instruction, result)
        (judge_validation_results[attribute] ||= []) << [instruction, result]
      end

      def judge_prefetch
        return if @judge_prefetched

        @judge_prefetched = true
        ::JudgeValidator.prefetch(self)
      end

      def judge_saw_text(text)
        (@judge_seen_texts ||= Set.new) << text
      end

      def reload(*)
        @judge_judgments = nil
        super
      end

      def initialize_dup(other)
        super
        @judge_judgments = nil
        @judge_validation_results = nil
      end

      private

      def run_validations!
        @judge_validation_results = {}
        @judge_prefetched = false
        @judge_seen_texts = nil
        super
      ensure
        judge_prune_judgments
      end

      def judge_prune_judgments
        return unless @judge_judgments

        seen = @judge_seen_texts || Set.new
        @judge_judgments.select! { |(text, _), (kind, _)| kind == :ok && seen.include?(text) }
      end
    end
  end
end

class JudgeValidator < ActiveModel::EachValidator # rubocop:disable Style/OneClassPerFile
  ERROR_MODES = %i[pass fail raise].freeze

  attr_reader :instruction, :polarity, :threshold, :question, :on_error

  def self.prefetch(record)
    groups = Hash.new { |hash, key| hash[key] = [] }

    record.class.validators.each do |validator|
      next unless validator.is_a?(JudgeValidator) && validator.applicable?(record)

      validator.attributes.each do |attribute|
        value = record.read_attribute_for_validation(attribute)
        next if value.blank? || record.judge_judgment(value.to_s, validator.instruction)

        group = groups[value.to_s]
        group << validator unless group.any? { |other| other.instruction == validator.instruction }
      end
    end

    groups.each { |text, validators| ask_batch(record, text, validators) if validators.size > 1 }
  end

  def self.ask_batch(record, text, validators)
    questions = validators.each_with_index.to_h { |validator, i| [:"judge_#{i}", validator.question] }
    results = Judge.ask(questions, text: text)
    validators.each_with_index do |validator, i|
      result = results[:"judge_#{i}"]
      raise Judge::InvalidResponseError, "no answer for #{validator.instruction}" unless result

      record.judge_store_judgment(text, validator.instruction, [:ok, result])
    end
  rescue Judge::Error => e
    validators.each { |validator| record.judge_store_judgment(text, validator.instruction, [:error, e]) }
  end

  def initialize(options)
    @polarity, @instruction = extract_judgment(options)
    @threshold = Float(options.fetch(:threshold, 0.5))
    @on_error = (options[:on_error] || :pass).to_sym
    unless ERROR_MODES.include?(@on_error)
      raise ArgumentError, "judge on_error: must be one of #{ERROR_MODES.inspect}"
    end

    @question = Judge.noul(@instruction)
    super
  end

  def validate_each(record, attribute, value)
    return if value.blank?

    kind, payload = judgment(record, attribute, value.to_s)
    if kind == :error
      handle_error(record, attribute, payload)
    else
      if record.respond_to?(:judge_record_validation_result)
        record.judge_record_validation_result(attribute, instruction, payload)
      end
      add_error(record, attribute, violation_type, options[:message]) if violated?(payload)
    end
  end

  def applicable?(record)
    return false unless context_match?(record)

    Array(options[:if]).all? { |condition| evaluate_condition(record, condition) } &&
      Array(options[:unless]).none? { |condition| evaluate_condition(record, condition) }
  end

  private

  def extract_judgment(options)
    refute = options[:refute]
    assert = options[:assert]
    if (refute && assert) || (refute.nil? && assert.nil?)
      raise ArgumentError, "judge validation needs exactly one of refute: or assert:"
    end

    refute ? [:refute, refute.to_s] : [:assert, assert.to_s]
  end

  def judgment(record, attribute, text)
    record.judge_prefetch if record.respond_to?(:judge_prefetch)
    record.judge_saw_text(text) if record.respond_to?(:judge_saw_text)
    cached = cached_judgment(record, attribute, text)
    return cached if cached

    outcome = ask(text)
    store_judgment(record, attribute, text, outcome)
    outcome
  end

  def cached_judgment(record, attribute, text)
    return record.judge_judgment(text, instruction) if record.respond_to?(:judge_judgment)

    cached_text, outcome = fallback_cache(record)&.[]([attribute, instruction])
    outcome if cached_text == text
  end

  def store_judgment(record, attribute, text, outcome)
    if record.respond_to?(:judge_store_judgment)
      record.judge_store_judgment(text, instruction, outcome)
    elsif outcome.first == :ok
      fallback_cache(record)&.[]=([attribute, instruction], [text, outcome])
    end
  end

  def fallback_cache(record)
    return record.instance_variable_get(:@judge_judgments) if record.frozen?

    record.instance_variable_get(:@judge_judgments) || record.instance_variable_set(:@judge_judgments, {})
  end

  def ask(text)
    [:ok, Judge.ask(question, text: text)]
  rescue Judge::Error => e
    [:error, e]
  end

  def violated?(result)
    polarity == :refute ? result.true?(threshold) : !result.true?(threshold)
  end

  def violation_type
    polarity == :refute ? :judge_refuted : :judge_unmatched
  end

  def handle_error(record, attribute, error)
    case on_error
    when :fail then add_error(record, attribute, :judge_unavailable, nil)
    when :raise then raise error
    else log_skipped(record, attribute, error)
    end
  end

  def log_skipped(record, attribute, error)
    Judge::Rails.logger&.warn("[judge] #{record.class} #{attribute} not checked: " \
                              "#{error.class}: #{error.message}")
  end

  def add_error(record, attribute, type, message)
    details = { instruction: instruction }
    details[:message] = message if message
    details[:strict] = options[:strict] if options[:strict]
    record.errors.add(attribute, type, **details)
  end

  def context_match?(record)
    contexts = Array(record.send(:validation_context)).map(&:to_s)
    on = options[:on]
    except_on = options[:except_on]
    return false if on && !Array(on).map(&:to_s).intersect?(contexts)
    return false if except_on && Array(except_on).map(&:to_s).intersect?(contexts)

    true
  end

  def run_proc(record, condition)
    condition.arity.zero? ? record.instance_exec(&condition) : record.instance_exec(record, &condition)
  end

  def evaluate_condition(record, condition)
    case condition
    when Symbol, String then record.send(condition)
    when Proc then run_proc(record, condition)
    else condition.respond_to?(:validate) ? condition.validate(record) : condition.call(record)
    end
  end
end
