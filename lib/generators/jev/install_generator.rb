# frozen_string_literal: true

require "rails/generators/base"

module Jev
  module Generators
    class InstallGenerator < ::Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Creates config/initializers/jev.rb and explains how to supply an API key."

      def create_initializer
        template "initializer.rb.tt", "config/initializers/jev.rb"
      end

      def print_next_steps
        return unless behavior == :invoke

        say ""
        say "Jev is installed.", :green
        say ""
        say "  1. Provide an API key, either as the JEV_API_KEY environment variable"
        say "     or as the Rails credential jev.api_key (bin/rails credentials:edit)."
        say "  2. Add judgments to a model, for example:"
        say ""
        say "       bin/rails generate jev:attribute Ticket urgency:noul intent:choice"
        say ""
        say "  3. Edit the generated questions, run bin/rails db:migrate, and call"
        say "     ticket.jev_refresh! to compute them."
        say ""
      end
    end
  end
end
