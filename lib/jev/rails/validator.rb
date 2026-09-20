# frozen_string_literal: true

module Jev
  module Rails
    module Validator
      extend ActiveSupport::Concern

      included do
        before_validation :jev_reset_validation_state
      end

      def jev_validation_results
        @jev_validation_results ||= {}
      end

      def jev_judgment(text, instruction)
        @jev_judgments && @jev_judgments[[text, instruction]]
      end

      def jev_store_judgment(text, instruction, outcome)
        @jev_judgments ||= {}
        @jev_judgments[[text, instruction]] = outcome
      end

      def jev_record_validation_result(attribute, instruction, result)
        (jev_validation_results[attribute] ||= []) << [instruction, result]
      end

      private

      def jev_reset_validation_state
        @jev_validation_results = {}
        @jev_judgments = {}
        ::JevValidator.prefetch(self)
        nil
      end
    end
  end
end

class JevValidator < ActiveModel::EachValidator # rubocop:disable Style/OneClassPerFile
  ERROR_MODES = %i[pass fail raise].freeze

  attr_reader :instruction, :polarity, :threshold, :question, :on_error

  def self.prefetch(record)
    groups = Hash.new { |hash, key| hash[key] = [] }

    record.class.validators.each do |validator|
      next unless validator.is_a?(JevValidator) && validator.applicable?(record)

      validator.attributes.each do |attribute|
        value = record.read_attribute_for_validation(attribute)
        next if value.blank?

        group = groups[value.to_s]
        group << validator unless group.any? { |other| other.instruction == validator.instruction }
      end
    end

    groups.each { |text, validators| ask_batch(record, text, validators) if validators.size > 1 }
  end

  def self.ask_batch(record, text, validators)
    questions = validators.each_with_index.to_h { |validator, i| [:"jev_#{i}", validator.question] }
    results = Jev.ask(questions, text: text)
    validators.each_with_index do |validator, i|
      record.jev_store_judgment(text, validator.instruction, [:ok, results.fetch(:"jev_#{i}")])
    end
  rescue StandardError => e
    validators.each { |validator| record.jev_store_judgment(text, validator.instruction, [:error, e]) }
  end

  def initialize(options)
    @polarity, @instruction = extract_judgment(options)
    @threshold = Float(options.fetch(:threshold, 0.5))
    @on_error = (options[:on_error] || :pass).to_sym
    unless ERROR_MODES.include?(@on_error)
      raise ArgumentError, "jev on_error: must be one of #{ERROR_MODES.inspect}"
    end

    @question = Jev.noul(@instruction)
    super
  end

  def validate_each(record, attribute, value)
    return if value.blank?

    kind, payload = judgment(record, value.to_s)
    if kind == :error
      handle_error(record, attribute, payload)
    else
      record.jev_record_validation_result(attribute, instruction, payload)
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
      raise ArgumentError, "jev validation needs exactly one of refute: or assert:"
    end

    refute ? [:refute, refute.to_s] : [:assert, assert.to_s]
  end

  def judgment(record, text)
    cached = record.jev_judgment(text, instruction)
    return cached if cached

    outcome = begin
      [:ok, Jev.ask(question, text: text)]
    rescue Jev::Error => e
      [:error, e]
    end
    record.jev_store_judgment(text, instruction, outcome)
    outcome
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
