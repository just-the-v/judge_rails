# frozen_string_literal: true

require "digest"
require "json"

module Judge
  class Question
    attr_reader :name, :instructions, :criteria, :digest

    def self.type
      self::TYPE
    end

    def initialize(instructions, criteria = nil, name: nil)
      raise ArgumentError, "instructions must not be empty" if instructions.to_s.strip.empty?

      @instructions = instructions.to_s.dup.freeze
      @criteria = normalize(criteria).freeze
      @name = name&.to_sym
      @digest = Digest::SHA256.hexdigest(JSON.generate([type, @instructions, @criteria]))[0, 16].freeze
      freeze
    end

    def type
      self.class.type
    end

    def with_name(new_name)
      return self if @name == new_name&.to_sym

      self.class.new(@instructions, @criteria, name: new_name)
    end

    def to_payload
      payload = { "type" => type, "instructions" => @instructions }
      payload["criteria"] = @criteria unless @criteria.nil?
      payload
    end

    def coerce(answer, name: @name)
      Result.new(name: name, question: self, payload: answer)
    end

    def ==(other)
      other.is_a?(Question) && other.type == type && other.instructions == instructions &&
        other.criteria == criteria && other.name == name
    end
    alias eql? ==

    def hash
      [self.class, @instructions, @criteria, @name].hash
    end

    def inspect
      "#<Judge::Question::#{self.class.name.split("::").last} #{@name.inspect} #{@instructions.inspect}>"
    end

    private

    def normalize(criteria)
      criteria
    end

    def entries(hash)
      hash.to_h { |key, value| [key.to_s, entry(value, nested: false)] }.tap do |normalized|
        duplicate_keys!(hash, normalized)
      end.freeze
    end

    def entry(value, nested: true)
      case value
      when Hash then nested_entries(value)
      when Array then value.map { |item| entry(item) }.freeze
      when Numeric, true, false then nested ? value : value.to_s.freeze
      else value.to_s.dup.freeze
      end
    end

    def nested_entries(hash)
      normalized = hash.compact.to_h { |key, value| [key.to_s, entry(value)] }
      duplicate_keys!(hash.compact, normalized)
      normalized.freeze
    end

    def duplicate_keys!(original, normalized)
      return if original.size == normalized.size

      keys = original.keys.map(&:to_s)
      duplicates = keys.select { |key| keys.count(key) > 1 }.uniq
      raise ArgumentError, "criteria keys #{duplicates.inspect} appear twice once converted to strings"
    end
  end
end
