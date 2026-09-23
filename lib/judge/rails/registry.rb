# frozen_string_literal: true

module Judge
  module Rails
    class Registry
      include Enumerable

      def initialize(parent = nil)
        @parent = parent
        @own = {}
        @version = 0
      end

      def add(definition)
        @own[definition.name] = definition
        @version += 1
        definition
      end

      def version
        @version + (@parent ? @parent.version : 0)
      end

      def [](name)
        @own[name.to_sym] || @parent&.[](name)
      end

      def fetch(name)
        self[name] || raise(ArgumentError, "no judge attribute named #{name.inspect}")
      end

      def to_h
        current = version
        return @flattened if @flattened_version == current

        @flattened_version = current
        @flattened = (@parent ? @parent.to_h : {}).merge(@own).freeze
      end

      def each(&)
        to_h.each_value(&)
      end

      def names
        to_h.keys
      end

      def empty?
        to_h.empty?
      end

      def inherit
        self.class.new(self)
      end
    end
  end
end
