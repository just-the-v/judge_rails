# frozen_string_literal: true

require "jev"
require "active_support"
require "active_record"
require "jev/rails/definition"
require "jev/rails/registry"
require "jev/rails/storage"
require "jev/rails/attributes"
require "jev/rails/migration"

module Jev
  module Rails
    OPTIONAL_PARTS = %w[refresh jobs scopes relation validator].freeze

    def self.load_optional_parts
      OPTIONAL_PARTS.each do |part|
        path = File.expand_path("rails/#{part}.rb", __dir__)
        require "jev/rails/#{part}" if File.exist?(path)
      end
    end

    def self.concerns
      %i[Attributes Refresh Jobs Scopes Validator].filter_map do |name|
        const_get(name) if const_defined?(name, false)
      end
    end
  end
end

Jev::Rails.load_optional_parts

ActiveSupport.on_load(:active_record) do
  Jev::Rails.concerns.each { |mod| include mod }
  extend Jev::Rails::Relation::ClassMethods if defined?(Jev::Rails::Relation::ClassMethods)
end
