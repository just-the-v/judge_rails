# frozen_string_literal: true

require "judge"
require "active_support"
require "active_record"
require "judge/rails/definition"
require "judge/rails/registry"
require "judge/rails/storage"
require "judge/rails/attributes"
require "judge/rails/migration"
require "judge/rails/refresh"
require "judge/rails/jobs"
require "judge/rails/scopes"
require "judge/rails/relation"
require "judge/rails/validator"

module Judge
  module Rails
    CONCERNS = [Attributes, Refresh, Jobs, Scopes, Validator].freeze
    LEASE_REGISTRY_LOCK = Mutex.new

    def self.logger
      Judge.config.logger || ActiveRecord::Base.logger
    end

    def self.log_failure(context, error)
      logger&.error("[judge] refresh failed for #{context}: #{error.class}: #{error.message}")
    end
  end
end

Judge::Pool.on_worker_exit do
  Judge::Rails::LEASE_REGISTRY_LOCK.synchronize do
    ActiveRecord::Base.connection_handler.connection_pool_list(:all).each do |pool|
      pool.release_connection if pool.active_connection?
    end
  end
end

ActiveSupport.on_load(:active_record) do
  Judge::Rails::CONCERNS.each { |mod| include mod }
  extend Judge::Rails::Relation::ClassMethods
end

ActiveSupport.on_load(:active_job) { require "judge/rails/refresh_job" }
