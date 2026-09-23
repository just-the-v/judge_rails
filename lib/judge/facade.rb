# frozen_string_literal: true

module Judge
  module Facade
    DEFAULT_NAME = :answer

    def noul(instructions, criteria = nil, name: nil)
      Question::Noul.new(instructions, criteria, name: name)
    end

    def choice(instructions, options, name: nil)
      Question::Choice.new(instructions, options, name: name)
    end

    def score(instructions, levels, name: nil)
      Question::Score.new(instructions, levels, name: name)
    end

    def decision_band(above, below)
      low = below || [1.0 - above, above].min
      unless low <= above
        raise ArgumentError,
              "decide needs below (#{low}) to be at or under above (#{above}), " \
              "otherwise no probability can land in :no or :unsure"
      end

      low
    end

    def ask(questions, text:, model: nil, adapter: nil)
      single = single_question?(questions)
      normalized = normalize_questions(questions)
      raise ArgumentError, "ask needs at least one question" if normalized.empty?

      results = (adapter || self.adapter).call(state: text, questions: normalized, model: model)
      single ? results.fetch(normalized.keys.first) : results
    end

    def normalize_questions(input)
      case input
      when Question then { input.name || DEFAULT_NAME => input }
      when String then { DEFAULT_NAME => noul(input) }
      when Hash then input.to_h { |name, q| [name.to_sym, coerce_question(q).with_name(name)] }
      when Array then named_from_array(input)
      else raise ArgumentError, "expected a Question, String, Array or Hash, got #{input.class}"
      end
    end

    def adapter
      return @adapter if @adapter && (@adapter_name.nil? || @adapter_name == config.adapter)

      @adapter_name = config.adapter
      @adapter = Adapter.build(@adapter_name)
    end

    def adapter=(adapter)
      @adapter_name = nil
      @adapter = adapter
    end

    private

    def single_question?(input)
      input.is_a?(Question) || input.is_a?(String)
    end

    def coerce_question(value)
      value.is_a?(String) ? noul(value) : value
    end

    def named_from_array(list)
      named = list.each_with_index.to_h do |q, i|
        question = coerce_question(q)
        name = question.name || :"q#{i}"
        [name, question.with_name(name)]
      end
      raise ArgumentError, "duplicate question names" if named.size != list.size

      named
    end
  end
end
