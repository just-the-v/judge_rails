# frozen_string_literal: true

require "judge"
require "active_support"
require "active_record"
require "judge/rails/definition"
require "judge/rails/registry"
require "judge/rails/storage"
require "judge/rails/attributes"
require "judge/rails/migration"

module Judge
  module Rails
    OPTIONAL_PARTS = %w[refresh jobs scopes relation validator].freeze

    def self.load_optional_parts
      OPTIONAL_PARTS.each do |part|
        path = File.expand_path("rails/#{part}.rb", __dir__)
        require "judge/rails/#{part}" if File.exist?(path)
      end
    end

    def self.concerns
      %i[Attributes Refresh Jobs Scopes Validator].filter_map do |name|
        const_get(name) if const_defined?(name, false)
      end
    end
  end
end

Judge::Rails.load_optional_parts

ActiveSupport.on_load(:active_record) do
  Judge::Rails.concerns.each { |mod| include mod }
  extend Judge::Rails::Relation::ClassMethods if defined?(Judge::Rails::Relation::ClassMethods)
end
