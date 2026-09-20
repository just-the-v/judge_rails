# frozen_string_literal: true

module Jev
  module Rails
    class Registry
      include Enumerable

      def initialize(parent = nil)
        @parent = parent
        @own = {}
      end

      def add(definition)
        @own[definition.name] = definition
      end

      def [](name)
        @own[name.to_sym] || @parent&.[](name)
      end

      def fetch(name)
        self[name] || raise(ArgumentError, "no jev attribute named #{name.inspect}")
      end

      def to_h
        (@parent ? @parent.to_h : {}).merge(@own)
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
