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

  def test_a_second_run_lands_below_judge_source
    Dir.mktmpdir do |root|
      write_model(root, "class Ticket < ApplicationRecord\n  judge_source { [subject, body] }\nend\n")
      generate(root, %w[Ticket urgency:noul])
      generate(root, %w[Ticket intent:choice])

      model = File.read(File.join(root, "app/models/ticket.rb"))

      assert_operator model.index("judge_source"), :<, model.index("judge_attribute :urgency")
      assert_operator model.index("judge_source"), :<, model.index("judge_attribute :intent")
    end
  end

  def test_destroy_removes_the_declarations
    Dir.mktmpdir do |root|
      write_model(root, "class Ticket < ApplicationRecord\n  judge_source { [subject, body] }\nend\n")
      generate(root, %w[Ticket urgency:noul])
      capture_io do
        Judge::Generators::AttributeGenerator.start(%w[Ticket urgency:noul], destination_root: root,
                                                                             behavior: :revoke)
      end

      refute_includes File.read(File.join(root, "app/models/ticket.rb")), "judge_attribute"
    end
  end

  def test_an_invalid_attribute_name_is_refused
    Dir.mktmpdir do |root|
      write_model(root, "class Ticket < ApplicationRecord\nend\n")
      _out, err = capture_io do
        Judge::Generators::AttributeGenerator.start(%w[Ticket urgency-level:noul], destination_root: root)
      end

      assert_match(/invalid attribute name/, err)
      assert_empty Dir[File.join(root, "db/**/*.rb")]
    end
  end

  def test_the_source_comes_from_the_model_text_columns
    Dir.mktmpdir do |root|
      write_model(root, "class JudgeTicket < ActiveRecord::Base\nend\n")
      Object.const_set(:JudgeTicket, Class.new(ActiveRecord::Base) { self.table_name = "judge_tickets" })
      generate(root, %w[JudgeTicket urgency:noul])

      assert_includes File.read(File.join(root, "app/models/judge_ticket.rb")), "judge_source { [body] }"
    ensure
      Object.send(:remove_const, :JudgeTicket) if Object.const_defined?(:JudgeTicket)
    end
  end

  def test_a_model_without_text_columns_gets_an_empty_source
    Dir.mktmpdir do |root|
      write_model(root, "class Account < ActiveRecord::Base\nend\n")
      ActiveRecord::Schema.define do
        create_table(:accounts, force: true) do |t|
          t.string :email, :encrypted_password, :reset_password_token
        end
      end
      Object.const_set(:Account, Class.new(ActiveRecord::Base) { self.table_name = "accounts" })
      generate(root, %w[Account urgency:noul])

      model = File.read(File.join(root, "app/models/account.rb"))

      assert_includes model, "judge_source { [] }"
      refute_includes model, "encrypted_password"
    ensure
      Object.send(:remove_const, :Account) if Object.const_defined?(:Account)
    end
  end

  def test_declarations_land_in_the_named_class_of_a_file_with_two
    Dir.mktmpdir do |root|
      write_model(root, "class Ticket < ApplicationRecord\n  judge_source { [body] }\nend\n\n" \
                        "class TicketArchive < Ticket\nend\n")
      generate(root, %w[Ticket urgency:noul])

      model = File.read(File.join(root, "app/models/ticket.rb"))

      assert_operator model.index("judge_attribute :urgency"), :<, model.index("class TicketArchive")
    end
  end

  def test_a_namespaced_model_with_a_source_does_not_crash
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "app/models/support"))
      File.write(File.join(root, "app/models/support/ticket.rb"),
                 "class Support::Ticket < ApplicationRecord\n  judge_source { [body] }\nend\n")
      generate(root, %w[Support::Ticket urgency:noul])

      assert_includes File.read(File.join(root, "app/models/support/ticket.rb")), "judge_attribute :urgency"
    end
  end

  def test_destroy_also_removes_the_generated_source
    Dir.mktmpdir do |root|
      write_model(root, "class Ticket < ApplicationRecord\nend\n")
      generate(root, %w[Ticket urgency:noul])
      capture_io do
        Judge::Generators::AttributeGenerator.start(%w[Ticket urgency:noul], destination_root: root,
                                                                             behavior: :revoke)
      end

      assert_equal "class Ticket < ApplicationRecord\n\nend\n",
                   File.read(File.join(root, "app/models/ticket.rb"))
    end
  end

  private

  def write_model(root, source)
    FileUtils.mkdir_p(File.join(root, "app/models"))
    name = source[/class (\w+)/, 1].gsub(/([a-z])([A-Z])/, '\1_\2').downcase
    File.write(File.join(root, "app/models/#{name}.rb"), source)
  end

  def generate(root, args)
    capture_io { Judge::Generators::AttributeGenerator.start(args, destination_root: root) }
  end
end
