# frozen_string_literal: true

require "rails_helper"
require "tmpdir"
require "rails/generators"
require "generators/judge/attribute_generator"
require "generators/judge/install_generator"

class AttributeGeneratorTest < Minitest::Test
  def test_generates_the_migration_and_the_model_declarations
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "app/models"))
      File.write(File.join(root, "app/models/ticket.rb"), "class Ticket < ApplicationRecord\nend\n")

      capture_io do
        Judge::Generators::AttributeGenerator.start(%w[Ticket urgency:noul intent:choice],
                                                    destination_root: root)
      end

      migration = Dir[File.join(root, "db/migrate/*_add_judge_urgency_intent_to_tickets.rb")].first

      assert migration, "no migration was written"
      assert_includes File.read(migration), "judge_attribute :tickets, :urgency, :noul"
      model = File.read(File.join(root, "app/models/ticket.rb"))

      assert_includes model, "judge_attribute :intent, Judge.choice("
    end
  end

  def test_the_initializer_keeps_a_key_read_from_the_environment
    Dir.mktmpdir do |root|
      capture_io { Judge::Generators::InstallGenerator.start([], destination_root: root) }

      initializer = File.read(File.join(root, "config/initializers/judge.rb"))

      assert_includes initializer, "config.api_key ||= Rails.application.credentials"
    end
  end
end
