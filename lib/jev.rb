# frozen_string_literal: true

require "jev/version"
require "jev/errors"
require "jev/configuration"
require "jev/question"
require "jev/question/noul"
require "jev/question/choice"
require "jev/question/score"
require "jev/result"
require "jev/result_set"
require "jev/facade"

module Jev
  extend Facade

  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
      config
    end

    def reset_config!
      @config = Configuration.new
      @client = nil
      config
    end
  end
end
