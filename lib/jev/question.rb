# frozen_string_literal: true

require "digest"
require "json"

module Jev
  class Question
    attr_reader :name, :instructions, :criteria, :digest

    def self.type
      name.split("::").last.downcase
    end

    def initialize(instructions, criteria = nil, name: nil)
      raise ArgumentError, "instructions must not be empty" if instructions.to_s.strip.empty?

      @instructions = instructions.to_s
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
      "#<Jev::Question::#{self.class.name.split("::").last} #{@name.inspect} #{@instructions.inspect}>"
    end

    private

    def normalize(criteria)
      criteria
    end
  end
end
