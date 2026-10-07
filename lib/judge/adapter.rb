# frozen_string_literal: true

module Judge
  # An adapter answers `call(state:, questions:, model:) -> Judge::ResultSet`, building each
  # result with `Judge::Result.from_values`. Nothing outside an adapter knows a wire format.
  module Adapter
    @lock = Mutex.new

    class << self
      def registry
        @registry ||= { jev: -> { Client.new }, clef: -> { Clef.new }, openai: -> { OpenAI.new } }
      end

      def register(name, &build)
        raise ArgumentError, "register needs a block returning an adapter" unless build

        @lock.synchronize do
          registry[name.to_sym] = build
          @built = nil
        end
        name.to_sym
      end

      def build(name)
        return name if name.respond_to?(:call)

        factory = registry[name.to_s.to_sym]
        raise ConfigurationError, unknown(name) unless factory

        factory.call
      end

      def resolve(name)
        return name if name.respond_to?(:call)

        built = @built
        return built.last if built&.first == name

        adapter = build(name)
        @lock.synchronize do
          @built = [name, adapter] unless @built&.first == name
          @built.last
        end
      end

      def names
        registry.keys
      end

      def reset!
        @lock.synchronize do
          @registry = nil
          @built = nil
        end
      end

      def reset_built!
        @lock.synchronize { @built = nil }
      end

      private

      def unknown(name)
        "unknown adapter #{name.inspect}. Known: #{names.map(&:inspect).join(", ")}. " \
          "Register one with Judge::Adapter.register(#{name.to_s.to_sym.inspect}) { ... }"
      end
    end
  end
end
