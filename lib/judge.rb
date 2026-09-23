# frozen_string_literal: true

require "judge/version"
require "judge/errors"
require "judge/configuration"
require "judge/question"
require "judge/question/noul"
require "judge/question/choice"
require "judge/question/score"
require "judge/result"
require "judge/result_set"
require "judge/facade"
require "judge/adapter"
require "judge/pool"

module Judge
  extend Facade

  autoload :Client, "judge/client"

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
      self.adapter = nil
      config
    end
  end
end
