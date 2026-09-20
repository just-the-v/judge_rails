# frozen_string_literal: true

require "digest"

module Jev
  module Rails
    class Definition
      CALLBACK_MODES = %i[async queue inline disabled].freeze
      ERROR_MODES = %i[pass fail raise].freeze

      attr_reader :name, :question, :source, :model, :callbacks, :if_condition, :on_error

      def initialize(name:, question:, source:, model: nil, sync: false, callbacks: nil,
                     if_condition: nil, on_error: :pass)
        @name = name.to_sym
        @question = question.with_name(@name)
        @source = source
        @model = model
        @callbacks = normalize_callbacks(callbacks, sync)
        @if_condition = if_condition
        @on_error = validate!(on_error.to_sym, ERROR_MODES, "on_error")
        validate_error_mode!
        freeze
      end

      def value_column
        @name
      end

      def sidecar_column
        :"#{@name}_jev"
      end

      def type
        @question.type
      end

      def digest
        @question.digest
      end

      def sync?
        @callbacks == :inline
      end

      def enqueue?
        %i[async queue].include?(@callbacks)
      end

      def state_for(record)
        text = case @source
               when Symbol, String then record.public_send(@source)
               when Proc then @source.arity.zero? ? record.instance_exec(&@source) : @source.call(record)
               else raise ArgumentError, "source must be a symbol or a callable"
               end
        Array(text).reject { |part| part.to_s.strip.empty? }.join("\n\n")
      end

      def state_digest(state)
        Digest::SHA256.hexdigest(state.to_s)[0, 16]
      end

      def applies_to?(record)
        return true if @if_condition.nil?

        @if_condition.is_a?(Proc) ? @if_condition.call(record) : record.public_send(@if_condition)
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

      def normalize_callbacks(callbacks, sync)
        return :inline if sync && callbacks.nil?
        return :async if callbacks.nil?

        mode = callbacks == false ? :disabled : callbacks.to_sym
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
