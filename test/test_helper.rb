# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "judge"
require "minitest/autorun"
require_relative "support/fake_jev"
require_relative "support/canned"
