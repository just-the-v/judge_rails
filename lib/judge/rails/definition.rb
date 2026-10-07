# frozen_string_literal: true

require "digest"

module Judge
  module Rails
    class Definition
      CALLBACK_MODES = %i[async inline disabled].freeze
      ERROR_MODES = %i[pass fail raise].freeze

      attr_reader :name, :question, :source, :model, :queue, :callbacks, :if_condition, :on_error

      def initialize(name:, question:, source:, model: nil, queue: nil, sync: false, callbacks: nil,
                     if_condition: nil, on_error: :pass)
        @name = name.to_sym
        @question = question.with_name(@name)
        @source = validate_source!(source)
        @model = model
        @queue = validate_queue!(queue)
        @callbacks = normalize_callbacks(callbacks, sync)
        @if_condition = validate_condition!(if_condition)
        @on_error = validate!(on_error.to_sym, ERROR_MODES, "on_error")
        validate_error_mode!
        freeze
      end

      def value_column
        @name
      end

      def sidecar_column
        :"#{@name}_judge"
      end

      def type
        @question.type
      end

      def digest
        model = effective_model
        return @question.digest if model == Judge::Configuration::DEFAULT_MODEL

        Digest::SHA256.hexdigest("#{@question.digest}:#{model}")[0, 16]
      end

      def effective_model
        @model || Judge.config.model
      end

      def sync?
        @callbacks == :inline
      end

      def enqueue?
        @callbacks == :async
      end

      def state_for(record)
        text = case @source
               when Symbol, String then record.public_send(@source)
               else evaluate(@source, record)
               end
        Array(text).reject { |part| part.to_s.strip.empty? }.join("\n\n")
      end

      def state_digest(state)
        Digest::SHA256.hexdigest(state.to_s)[0, 16]
      end

      def applies_to?(record)
        return true if @if_condition.nil?

        @if_condition.is_a?(Proc) ? evaluate(@if_condition, record) : record.public_send(@if_condition)
      end

      def cast(result)
        case type
        when "noul", "score" then result.value
        when "choice" then result.value.to_s
        end
      end

      def sidecar(result, state_digest:, model: nil, latency: nil)
        {
          "digest" => digest,
          "state_digest" => state_digest,
          "computed_at" => Time.now.utc.iso8601,
          "probability" => result.probability,
          "confidence" => result.confidence,
          "probabilities" => result.probabilities,
          "legend" => result.legend.empty? ? nil : result.legend,
          "model" => model,
          "latency" => latency
        }.compact
      end

      def stale?(value:, sidecar:, state:)
        return true if value.nil?

        meta = sidecar || {}
        return true if meta["digest"] != digest

        meta["state_digest"] != state_digest(state)
      end

      private

      def evaluate(callable, record)
        callable.arity.zero? ? record.instance_exec(&callable) : callable.call(record)
      end

      def validate_source!(source)
        return source if source.is_a?(Symbol) || source.is_a?(String) || source.is_a?(Proc)

        raise ArgumentError, "judge_attribute #{@name.inspect} source must be a Symbol, String or Proc, " \
                             "got #{source.class}"
      end

      def validate_queue!(queue)
        return nil if queue.nil?
        return queue.to_s.strip if (queue.is_a?(Symbol) || queue.is_a?(String)) && !queue.to_s.strip.empty?

        raise ArgumentError, "judge_attribute #{@name.inspect} queue must be a non-blank Symbol or String, " \
                             "got #{queue.inspect}"
      end

      def validate_condition!(condition)
        return condition if condition.nil? || condition.is_a?(Symbol) || condition.is_a?(Proc)

        raise ArgumentError, "if_condition must be a Symbol or a Proc, got #{condition.class}"
      end

      def normalize_callbacks(callbacks, sync)
        return :inline if sync && callbacks.nil?
        return :async if callbacks.nil?
        if sync
          raise ArgumentError,
                "sync: true already means inline callbacks; drop callbacks: #{callbacks.inspect}"
        end

        mode = case callbacks
               when false then :disabled
               when true then :async
               else callbacks.to_s.to_sym
               end
        validate!(mode, CALLBACK_MODES, "callbacks")
      end

      def validate_error_mode!
        return if @on_error == :pass || @callbacks == :inline

        raise ArgumentError,
              "on_error: #{@on_error.inspect} only applies to a synchronous attribute. " \
              "#{@name.inspect} is #{@callbacks.inspect}, so the record is already committed by the time " \
              "the call runs and nothing can be blocked. Pass sync: true, or leave on_error as :pass."
      end

      def validate!(value, allowed, label)
        return value if allowed.include?(value)

        raise ArgumentError, "#{label} must be one of #{allowed.inspect}, got #{value.inspect}"
      end
    end
  end
end
