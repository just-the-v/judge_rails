# frozen_string_literal: true

require "active_record"

module Jev
  module Rails
    module Migration
      VALUE_TYPES = { noul: :float, score: :float, choice: :string }.freeze

      class << self
        def value_type(type)
          VALUE_TYPES.fetch(type.to_s.to_sym) do
            raise ArgumentError,
                  "unknown jev attribute type #{type.inspect}, expected one of #{VALUE_TYPES.keys.inspect}"
          end
        end

        def sidecar_column(name)
          :"#{name}_jev"
        end

        def sidecar_type(connection = nil)
          postgresql?(connection) ? :jsonb : :json
        end

        def postgresql?(connection = nil)
          adapter_name(connection).start_with?("postgres")
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

      def jev_attribute(table, name, type, index: true, null: true)
        sidecar = Migration.sidecar_column(name)
        add_column table, name, Migration.value_type(type), null: null
        add_column table, sidecar, Migration.sidecar_type(connection), null: false, default: {}
        return unless index

        add_index table, name
        add_index table, sidecar, using: :gin if Migration.postgresql?(connection)
      end

      def remove_jev_attribute(table, name, type = nil, index: true, null: true)
        sidecar = Migration.sidecar_column(name)
        if index
          remove_index table, sidecar, using: :gin if Migration.postgresql?(connection)
          remove_index table, name
        end
        remove_column table, sidecar, Migration.sidecar_type(connection), null: false, default: {}
        remove_column table, name, (type && Migration.value_type(type)), null: null
      end

      module TableDefinition
        def jev_attribute(name, type, index: true, null: true)
          sidecar = Migration.sidecar_column(name)
          conn = jev_connection
          gin = index && Migration.postgresql?(conn)
          column name, Migration.value_type(type), null: null, index: index
          column sidecar, Migration.sidecar_type(conn), null: false, default: {},
                                                        index: gin ? { using: :gin } : nil
        end

        private

        def jev_connection
          return unless instance_variable_defined?(:@conn)

          conn = instance_variable_get(:@conn)
          conn if conn.respond_to?(:adapter_name)
        end
      end
    end
  end
end

ActiveSupport.on_load(:active_record) do
  ActiveRecord::Migration.include(Jev::Rails::Migration)
  ActiveRecord::ConnectionAdapters::TableDefinition.include(Jev::Rails::Migration::TableDefinition)
end
