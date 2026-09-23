# frozen_string_literal: true

require "rails/generators/named_base"
require "rails/generators/active_record"

module Judge
  module Generators
    class AttributeGenerator < ::Rails::Generators::NamedBase
      include ::ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Adds Judge judgment attributes to a model: a migration plus the model declarations."

      argument :judge_attributes, type: :array, default: [], banner: "name:noul name:choice name:score"
      class_option :database, type: :string, aliases: %i[--db],
                              desc: "The database whose migrations path receives the migration"

      TYPES = %w[noul choice score].freeze
      NAME = /\A[a-z_][a-z0-9_]*\z/

      QUESTION_ARGUMENTS = {
        "noul" => "",
        "choice" => ", %w[first_option second_option third_option]",
        "score" => ", 1..5"
      }.freeze

      def validate_pairs
        raise ::Rails::Generators::Error, "give at least one name:type pair" if pairs.empty?

        invalid = pairs.map(&:first).grep_v(NAME)
        unless invalid.empty?
          raise ::Rails::Generators::Error,
                "invalid attribute name(s) #{invalid.join(", ")}: " \
                "use lowercase letters, digits and underscores"
        end

        unknown = pairs.reject { |_, type| TYPES.include?(type) }
        return if unknown.empty?

        raise ::Rails::Generators::Error,
              "unknown judge type(s) #{unknown.map(&:last).uniq.join(", ")}, expected #{TYPES.join(", ")}"
      end

      def create_migration_file
        migration_template "migration.rb.tt", File.join(db_migrate_path, "#{migration_basename}.rb")
      end

      def inject_model_declarations
        return say_status(:skip, "#{model_path} not found", :yellow) unless model_source
        return remove_declarations if behavior == :revoke

        declarations = missing_declarations
        return say_status(:identical, model_path, :blue) if declarations.empty?

        if judge_source?
          inject_into_file model_path, declarations.join,
                           after: /\A#{Regexp.escape(model_source[0...insertion_point])}/
        else
          inject_into_class model_path, class_name, "#{source_line}#{declarations.join}\n"
        end
      end

      private

      def pairs
        @pairs ||= judge_attributes.map do |pair|
          name, type = pair.split(":", 2)
          [name, type.to_s]
        end
      end

      def migration_basename
        "add_judge_#{pairs.map(&:first).join("_")}_to_#{table_name}"
      end

      def model_path
        File.join("app", "models", class_path, "#{file_name}.rb")
      end

      def model_source
        return @model_source if defined?(@model_source)

        full = File.join(destination_root, model_path)
        @model_source = File.exist?(full) ? File.read(full) : nil
      end

      def judge_source?
        model_source.to_s.match?(/^\s*judge_source\b/)
      end

      def insertion_point
        lines = model_source.lines
        class_index = lines.index do |line|
          line.match?(/^\s*class\s+#{Regexp.escape(class_name.demodulize)}\b/)
        end
        indent = lines[class_index][/\A\s*/]
        closing = lines.rindex { |line| line.match?(/\A#{indent}end\b/) }
        lines[0...closing].join.length
      end

      def source_line
        columns = text_columns
        return "  judge_source { [#{columns.join(", ")}] }\n" if columns.any?

        "  judge_source { [] } # TODO: the attributes Judge should read; nothing is judged until you set it\n"
      end

      def text_columns
        model = class_name.safe_constantize
        return [] unless model.respond_to?(:columns)

        text = model.columns.select { |c| c.type == :text }.map(&:name)
        text = model.columns.select { |c| c.type == :string }.map(&:name) if text.empty?
        text - model.columns.map(&:name).grep(/_judge\z|_type\z/)
      rescue StandardError
        []
      end

      def missing_declarations
        pairs.reject { |name, _| declared?(name) }.map { |name, type| "  #{declaration(name, type)}\n" }
      end

      def remove_declarations
        pairs.each do |name, type|
          gsub_file model_path, "  #{declaration(name, type)}\n", "", force: true
        end
      end

      def declared?(name)
        model_source.to_s.match?(/^\s*judge_attribute\s+:#{Regexp.escape(name)}\b/)
      end

      def declaration(name, type)
        prompt = %("TODO: describe the judgment for #{name}"#{QUESTION_ARGUMENTS.fetch(type)})
        "judge_attribute :#{name}, Judge.#{type}(#{prompt})"
      end
    end
  end
end
