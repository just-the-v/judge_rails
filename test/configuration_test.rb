# frozen_string_literal: true

require "test_helper"

class ConfigurationQueueTest < Minitest::Test
  def with_queue_env(value)
    previous = ENV.fetch("JUDGE_QUEUE", nil)
    value.nil? ? ENV.delete("JUDGE_QUEUE") : ENV["JUDGE_QUEUE"] = value
    yield Judge::Configuration.new
  ensure
    ENV["JUDGE_QUEUE"] = previous
  end

  def test_the_queue_defaults_to_default
    with_queue_env(nil) { |c| assert_equal "default", c.queue }
    with_queue_env("  ") { |c| assert_equal "default", c.queue }
  end

  def test_the_environment_overrides_the_default
    with_queue_env(" p3 ") { |c| assert_equal "p3", c.queue }
  end

  def test_the_setter_overrides_the_environment_and_stores_a_string
    with_queue_env("p3") do |c|
      c.queue = :autopilot

      assert_equal "autopilot", c.queue
    end
  end

  def test_a_blank_or_odd_queue_raises
    config = Judge::Configuration.new

    assert_raises(ArgumentError) { config.queue = "" }
    assert_raises(ArgumentError) { config.queue = nil }
    assert_raises(ArgumentError) { config.queue = 3 }
  end

  def test_inspect_shows_the_queue
    config = Judge::Configuration.new
    config.queue = "p2"

    assert_includes config.inspect, 'queue="p2"'
  end
end
