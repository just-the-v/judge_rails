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

      TYPES = %w[noul choice score].freeze

      QUESTION_ARGUMENTS = {
        "noul" => "",
        "choice" => ", %w[first_option second_option third_option]",
        "score" => ", 1..5"
      }.freeze

      def validate_pairs
        raise ::Rails::Generators::Error, "give at least one name:type pair" if pairs.empty?

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

        lines = []
        unless judge_source?
          lines << "  judge_source { [subject, body] } # TODO: the attributes Judge should read\n"
        end
        lines.concat(missing_declarations)
        return say_status(:identical, model_path, :blue) if lines.empty?

        inject_into_class model_path, class_name, "#{lines.join}\n"
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

      def missing_declarations
        pairs.reject { |name, _| declared?(name) }
             .map { |name, type| "  #{declaration(name, type)}\n" }
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
