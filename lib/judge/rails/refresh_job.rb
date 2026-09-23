# frozen_string_literal: true

module Judge
  module Rails
    class RefreshJob < ActiveJob::Base
      queue_as { "default" }
      retry_on(*Jobs::RETRYABLE_ERRORS, wait: :polynomially_longer, attempts: 5)

      def perform(model_name, id, names = [])
        payload = Jobs::Payload.new(model: model_name.constantize, ids: [id], names: names)
        Jobs.perform(payload, raise_retryable: true)
      end
    end
  end
end
