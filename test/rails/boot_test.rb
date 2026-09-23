# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

class BootTest < Minitest::Test
  def test_requiring_the_gem_name_loads_the_rails_layer
    lib = File.expand_path("../../lib", __dir__)
    script = 'require "judge_rails"; print ActiveRecord::Base.respond_to?(:judge_attribute)'
    out, status = Open3.capture2e(RbConfig.ruby, "-I", lib, "-e", script)

    assert_predicate status, :success?, out
    assert_equal "true", out
  end
end
