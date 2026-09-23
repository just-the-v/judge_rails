# frozen_string_literal: true

module Judge
  # An adapter answers `call(state:, questions:, model:) -> Judge::ResultSet`, building each
  # result with `Judge::Result.from_values`. Nothing outside an adapter knows a wire format.
  module Adapter
    class << self
      def registry
        @registry ||= { jev: -> { Client.new } }
      end

      def register(name, &build)
        raise ArgumentError, "register needs a block returning an adapter" unless build

        registry[name.to_sym] = build
        name.to_sym
      end

      def build(name)
        factory = registry[name.to_sym]
        raise ConfigurationError, unknown(name) unless factory

        factory.call
      end

      def names
        registry.keys
      end

      def reset!
        @registry = nil
      end

      private

      def unknown(name)
        "unknown adapter #{name.inspect}. Known: #{names.map(&:inspect).join(", ")}. " \
          "Register one with Judge::Adapter.register(#{name.to_sym.inspect}) { ... }"
      end
    end
  end
end
