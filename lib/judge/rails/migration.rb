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

        def sidecar_column(name)
          :"#{name}_judge"
        end

        def sidecar_type(connection = nil)
          postgresql?(connection) ? :jsonb : :json
        end

        def postgresql?(connection = nil)
          adapter_name(connection).start_with?("postgres")
        end

        def sidecar_options(connection = nil)
          mysql?(connection) ? {} : { null: false, default: {} }
        end

        def mysql?(connection = nil)
          adapter_name(connection).match?(/mysql|trilogy/)
        end

        def adapter_name(connection = nil)
          target = connection
          target = target.delegate if target.respond_to?(:delegate)
          target = default_connection unless target.respond_to?(:adapter_name)
          target.adapter_name.to_s.downcase
        end

        def default_connection
          if ActiveRecord::Base.respond_to?(:lease_connection)
            ActiveRecord::Base.lease_connection
          else
            ActiveRecord::Base.connection
          end
        end
      end

      def judge_attribute(table, name, type, index: true, null: true)
        sidecar = Migration.sidecar_column(name)
        add_column table, name, Migration.value_type(type), null: null,
                                                            **Migration.value_options(type, connection)
        add_column table, sidecar, Migration.sidecar_type(connection), **Migration.sidecar_options(connection)
        return unless index

        add_index table, name
        add_index table, sidecar, using: :gin if Migration.postgresql?(connection)
      end

      def remove_judge_attribute(table, name, type = nil, index: true, null: true)
        sidecar = Migration.sidecar_column(name)
        if index
          remove_index table, sidecar, using: :gin if Migration.postgresql?(connection)
          remove_index table, name
        end
        remove_column table, sidecar, Migration.sidecar_type(connection),
                      **Migration.sidecar_options(connection)
        remove_column table, name, (type && Migration.value_type(type)), null: null
      end

      module TableDefinition
        def judge_attribute(name, type, index: true, null: true)
          sidecar = Migration.sidecar_column(name)
          conn = judge_connection
          gin = index && Migration.postgresql?(conn)
          column name, Migration.value_type(type), null: null, index: index,
                                                   **Migration.value_options(type, conn)
          column sidecar, Migration.sidecar_type(conn), **Migration.sidecar_options(conn),
                                                        index: gin ? { using: :gin } : nil
        end

        private

        def judge_connection
          return unless instance_variable_defined?(:@conn)

          conn = instance_variable_get(:@conn)
          conn if conn.respond_to?(:adapter_name)
        end
      end
    end
  end
end

ActiveSupport.on_load(:active_record) do
  ActiveRecord::Migration.include(Judge::Rails::Migration)
  ActiveRecord::ConnectionAdapters::TableDefinition.include(Judge::Rails::Migration::TableDefinition)
end
