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
require "judge/decision"
require "judge/facade"
require "judge/adapter"
require "judge/pool"

module Judge
  extend Facade

  autoload :Client, "judge/client"
  autoload :Clef, "judge/clef"

  @config_lock = Mutex.new

  class << self
    def config
      @config || @config_lock.synchronize { @config ||= Configuration.new }
    end

    def configure
      yield config
      config
    end

    def reset_config!
      @config = Configuration.new
      self.adapter = nil
      Adapter.reset_built!
      config
    end
  end
end
