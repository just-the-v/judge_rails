# frozen_string_literal: true

require "rails_helper"
require "judge/rails/migration"

class JudgeMigrationHelperTest < JudgeRailsTest
  TABLE = :judge_migrated_tickets

  def setup
    super
    ActiveRecord::Migration.verbose = false
    connection.drop_table(TABLE, if_exists: true)
    connection.create_table(TABLE) do |t|
      t.string :subject
      t.text :body
    end
  end

  def teardown
    connection.drop_table(TABLE, if_exists: true)
    super
  end

  def test_noul_and_score_get_a_float_value_column
    run_migration { judge_attribute TABLE, :urgency, :noul }
    run_migration { judge_attribute TABLE, :severity, :score }

    assert_equal :float, column(:urgency).type
    assert_equal :float, column(:severity).type
  end

  def test_choice_gets_a_string_value_column
    run_migration { judge_attribute TABLE, :intent, :choice }

    assert_equal :string, column(:intent).type
  end

  def test_sidecar_column_is_json_with_a_not_null_empty_default
    skip "MySQL rejects a default on a JSON column" if mysql?
    run_migration { judge_attribute TABLE, :urgency, :noul }
    sidecar = column(:urgency_judge)

    assert_equal :json, sidecar.type
    refute sidecar.null
    assert_equal({}, normalize_default(sidecar.default))
  end

  def test_mysql_sidecar_is_nullable_json_and_value_is_double_precision
    skip "MySQL only" unless mysql?
    run_migration { judge_attribute TABLE, :urgency, :noul }

    assert_equal :json, column(:urgency_judge).type
    assert column(:urgency_judge).null
    assert_equal "double", column(:urgency).sql_type
  end

  def test_value_column_is_nullable_and_refuses_not_null
    run_migration { judge_attribute TABLE, :urgency, :noul }

    assert column(:urgency).null
    error = assert_raises(ArgumentError) do
      run_migration do
        judge_attribute TABLE, :intent, :choice, null: false
      end
    end
    assert_match(/must allow NULL/, error.message)
  end

  def test_change_table_form
    connection.change_table(TABLE) { |t| t.judge_attribute :urgency, :noul }
    reload_columns

    assert_equal :float, column(:urgency).type
    assert_equal :json, column(:urgency_judge).type
    assert_includes indexed_columns, ["urgency"]
  end

  def test_an_untyped_remove_is_irreversible_with_a_clear_message
    run_migration { judge_attribute TABLE, :urgency, :noul }
    migration = migration_for { remove_judge_attribute TABLE, :urgency }
    migration.migrate(:up)

    error = assert_raises(ActiveRecord::IrreversibleMigration) { migration.migrate(:down) }
    assert_match(/needs its type/, error.message)
  end

  def test_value_column_is_indexed_and_no_gin_index_on_sqlite
    run_migration { judge_attribute TABLE, :urgency, :noul }

    assert_includes indexed_columns, ["urgency"]
    refute_includes indexed_columns, ["urgency_judge"]
  end

  def test_index_option_can_be_disabled
    run_migration { judge_attribute TABLE, :urgency, :noul, index: false }

    assert_empty indexed_columns
  end

  def test_unknown_type_raises_argument_error
    error = assert_raises(ArgumentError) do
      run_migration { judge_attribute TABLE, :urgency, :vibe }
    end

    assert_match(/unknown judge attribute type/, error.message)
  end

  def test_migration_is_reversible
    migration = migration_for { judge_attribute TABLE, :urgency, :noul }
    migration.migrate(:up)

    assert column(:urgency)
    assert column(:urgency_judge)

    migration.migrate(:down)
    reload_columns

    assert_nil column(:urgency)
    assert_nil column(:urgency_judge)
    assert_empty indexed_columns
  end

  def test_remove_judge_attribute_drops_both_columns_and_the_index
    run_migration { judge_attribute TABLE, :urgency, :noul }
    run_migration { remove_judge_attribute TABLE, :urgency }

    assert_nil column(:urgency)
    assert_nil column(:urgency_judge)
    assert_empty indexed_columns
  end

  def test_remove_judge_attribute_is_reversible_when_given_a_type
    run_migration { judge_attribute TABLE, :urgency, :noul }
    migration = migration_for { remove_judge_attribute TABLE, :urgency, :noul }
    migration.migrate(:up)
    reload_columns

    assert_nil column(:urgency)

    migration.migrate(:down)
    reload_columns

    assert_equal :float, column(:urgency).type
    assert_equal :json, column(:urgency_judge).type
  end

  def test_table_definition_form_inside_create_table
    connection.drop_table(TABLE, if_exists: true)
    connection.create_table(TABLE) do |t|
      t.string :subject
      t.judge_attribute :urgency, :noul
      t.judge_attribute :intent, :choice
    end

    assert_equal :float, column(:urgency).type
    assert_equal :string, column(:intent).type
    assert_equal :json, column(:urgency_judge).type
    refute column(:urgency_judge).null unless mysql?
    assert_includes indexed_columns, ["urgency"]
  end

  def test_generated_schema_round_trips_a_real_judge_refresh
    run_migration { judge_attribute TABLE, :urgency, :noul }
    run_migration { judge_attribute TABLE, :intent, :choice }

    klass = migrated_model
    record = klass.create!(subject: "Refund now", body: "I was charged twice")

    assert_equal %i[urgency intent].sort, record.judge_refresh.sort
    record.save!

    reloaded = klass.find(record.id)

    assert_in_delta 0.91, reloaded.urgency
    assert_equal "billing", reloaded.intent
    assert_in_delta 0.88, reloaded.intent_judge["confidence"]
    assert_equal "billing", reloaded.intent_judge["probabilities"].max_by { |_, v| v }.first
    refute_predicate reloaded, :judge_stale?
  end

  def test_mysql_gets_a_sidecar_without_a_literal_default
    mysql = Struct.new(:adapter_name).new("Mysql2")
    trilogy = Struct.new(:adapter_name).new("Trilogy")
    postgres = Struct.new(:adapter_name).new("PostgreSQL")

    assert_empty Judge::Rails::Migration.sidecar_options(mysql)
    assert_empty Judge::Rails::Migration.sidecar_options(trilogy)
    assert_equal({ null: false, default: {} }, Judge::Rails::Migration.sidecar_options(postgres))
  end

  private

  def connection
    ActiveRecord::Base.connection
  end

  def mysql?
    Judge::Rails::Migration.mysql?(connection)
  end

  def migration_for(&block)
    klass = Class.new(ActiveRecord::Migration::Current) do
      define_method(:change, &block)
    end
    klass.new.tap { |m| m.verbose = false }
  end

  def run_migration(&)
    migration_for(&).migrate(:up)
    reload_columns
  end

  def reload_columns
    connection.schema_cache.clear!
    ActiveRecord::Base.descendants.each(&:reset_column_information)
  end

  def column(name)
    connection.columns(TABLE).find { |c| c.name == name.to_s }
  end

  def indexed_columns
    connection.indexes(TABLE).map(&:columns)
  end

  def normalize_default(value)
    value.is_a?(String) ? JSON.parse(value) : value
  end

  def migrated_model
    table = TABLE
    Class.new(ActiveRecord::Base) do
      self.table_name = table
      judge_source { [subject, body] }
      judge_attribute :urgency, Judge.noul("Does this need a human within the hour?")
      judge_attribute :intent, Judge.choice("What is this about?", %w[billing technical sales])
    end
  end
end
