# frozen_string_literal: true

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

      def reload(*)
        @judge_judgments = nil
        super
      end

      private

      def run_validations!
        @judge_validation_results = {}
        @judge_prefetched = false
        super
      ensure
        @judge_judgments&.reject! { |_key, (kind, _payload)| kind == :error }
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
      record.judge_store_judgment(text, validator.instruction, [:ok, results.fetch(:"judge_#{i}")])
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

    kind, payload = judgment(record, value.to_s)
    if kind == :error
      handle_error(record, attribute, payload)
    else
      if record.respond_to?(:judge_record_validation_result)
        record.judge_record_validation_result(attribute, instruction, payload)
      end
      record.errors.add(attribute, error_message) if violated?(payload)
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

  def judgment(record, text)
    record.judge_prefetch if record.respond_to?(:judge_prefetch)
    cached = cached_judgment(record, text)
    return cached if cached

    outcome = ask(text)
    store_judgment(record, text, outcome)
    outcome
  end

  def cached_judgment(record, text)
    return record.judge_judgment(text, instruction) if record.respond_to?(:judge_judgment)

    fallback_cache(record)[[text, instruction]]
  end

  def store_judgment(record, text, outcome)
    if record.respond_to?(:judge_store_judgment)
      record.judge_store_judgment(text, instruction, outcome)
    elsif outcome.first == :ok
      fallback_cache(record)[[text, instruction]] = outcome
    end
  end

  def fallback_cache(record)
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

  def handle_error(record, attribute, error)
    case on_error
    when :fail then record.errors.add(attribute, error_message)
    when :raise then raise error
    end
  end

  def error_message
    options[:message] || default_message
  end

  def default_message
    polarity == :refute ? %(matched "#{instruction}") : %(did not match "#{instruction}")
  end

  def context_match?(record)
    on = options[:on]
    return true if on.nil?

    context = record.send(:validation_context)
    Array(on).map(&:to_sym).include?(context&.to_sym)
  end

  def evaluate_condition(record, condition)
    return record.send(condition) unless condition.is_a?(Proc)

    condition.arity.zero? ? record.instance_exec(&condition) : condition.call(record)
  end
end
