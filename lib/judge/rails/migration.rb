# frozen_string_literal: true

require "active_record"

module Judge
  module Rails
    module Migration
      VALUE_TYPES = { noul: :float, score: :float, choice: :string }.freeze

      class << self
        def value_type(type)
          VALUE_TYPES.fetch(type.to_s.to_sym) do
            raise ArgumentError,
                  "unknown judge attribute type #{type.inspect}, expected one of #{VALUE_TYPES.keys.inspect}"
          end
        end

        def value_options(type, connection = nil)
          value_type(type) == :float && mysql?(connection) ? { limit: 53 } : {}
        end

        def nullable!(null)
          return if null

          raise ArgumentError, "a judge value column must allow NULL: it is empty until judged and cleared " \
                               "when its text goes blank"
        end

        def sidecar_column(name)
          :"#{name}_judge"
        end

        def sidecar_type(connection = nil)
          postgresql?(connection) ? :jsonb : :json
        end

        def sidecar_options(connection = nil)
          mysql?(connection) ? {} : { null: false, default: {} }
        end

        def postgresql?(connection = nil)
          adapter_name(connection).start_with?("postg")
        end

        def mysql?(connection = nil)
          adapter_name(connection).match?(/mysql|trilogy/)
        end

        def adapter_name(connection = nil)
          target = connection.respond_to?(:delegate) ? connection.delegate : connection
          target = ActiveRecord::Base.lease_connection unless target.respond_to?(:adapter_name)
          target.adapter_name.to_s.downcase
        end
      end

      def judge_attribute(table, name, type, index: true, null: true)
        Migration.nullable!(null)
        add_column table, name, Migration.value_type(type), null: null,
                                                            **Migration.value_options(type, connection)
        add_column table, Migration.sidecar_column(name), Migration.sidecar_type(connection),
                   **Migration.sidecar_options(connection)
        add_index table, name if index
      end

      def remove_judge_attribute(table, name, type = nil, index: true, null: true)
        if type.nil? && connection.is_a?(ActiveRecord::Migration::CommandRecorder)
          raise ActiveRecord::IrreversibleMigration,
                "remove_judge_attribute #{table.inspect}, #{name.inspect} needs its type " \
                "(:noul, :choice or :score) to be reversible"
        end

        sidecar = Migration.sidecar_column(name)
        remove_index table, name, if_exists: true if index
        remove_column table, sidecar, Migration.sidecar_type(connection),
                      **Migration.sidecar_options(connection)
        value_options = type ? Migration.value_options(type, connection) : {}
        remove_column table, name, (type && Migration.value_type(type)), null: null, **value_options
      end

      module TableDefinition
        def judge_attribute(name, type, index: true, null: true)
          Migration.nullable!(null)
          conn = judge_connection
          column name, Migration.value_type(type), null: null, index: index,
                                                   **Migration.value_options(type, conn)
          column Migration.sidecar_column(name), Migration.sidecar_type(conn),
                 **Migration.sidecar_options(conn)
        end

        private

        def judge_connection
          conn = instance_variable_get(:@conn)
          conn if conn.respond_to?(:adapter_name)
        end
      end

      module Table
        def judge_attribute(name, type, index: true, null: true)
          Migration.nullable!(null)
          column name, Migration.value_type(type), null: null, **Migration.value_options(type, @base)
          column Migration.sidecar_column(name), Migration.sidecar_type(@base),
                 **Migration.sidecar_options(@base)
          index name if index
        end
      end
    end
  end
end

ActiveSupport.on_load(:active_record) do
  ActiveRecord::Migration.include(Judge::Rails::Migration)
  ActiveRecord::ConnectionAdapters::TableDefinition.include(Judge::Rails::Migration::TableDefinition)
  ActiveRecord::ConnectionAdapters::Table.include(Judge::Rails::Migration::Table)
end
