# frozen_string_literal: true

require "test_helper"
require "judge/client"
require "timeout"

class PoolTest < Minitest::Test
  def test_nothing_to_do_makes_no_thread
    assert_empty Judge::Pool.map([]) { flunk "should not run" }
  end

  def test_order_is_preserved_whatever_the_thread_finishes_first
    # The first item sleeps longest, so a pool that returned completion order would invert this.
    delays = [0.05, 0.03, 0.01, 0.0]
    mapped = Judge::Pool.map(delays, concurrency: 4) do |delay|
      sleep(delay)
      delay
    end

    assert_equal delays, mapped
  end

  def test_one_worker_runs_inline_without_creating_a_thread
    caller_thread = Thread.current
    seen = Judge::Pool.map([1, 2, 3], concurrency: 1) { Thread.current }

    assert_equal [caller_thread] * 3, seen
  end

  def test_a_single_item_runs_inline
    caller_thread = Thread.current

    assert_equal [caller_thread], Judge::Pool.map([1], concurrency: 8) { Thread.current }
  end

  def test_work_really_overlaps
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Judge::Pool.map(Array.new(8, 0.1), concurrency: 8) { |d| sleep(d) }
    duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator duration, :<, 0.4, "8 x 0.1s took #{duration.round(3)}s, so they did not overlap"
  end

  def test_more_workers_than_items_still_answers_every_item
    # How many of the 32 workers actually pick something up is a race, so the only deterministic
    # facts are that the work left the caller thread and that both items came back.
    threads = Judge::Pool.map([1, 2], concurrency: 32) { Thread.current }

    assert_equal 2, threads.size
    refute_includes threads, Thread.current
  end

  def test_the_first_error_reaches_the_caller
    error = assert_raises(RuntimeError) do
      Judge::Pool.map(1..20, concurrency: 4) { |i| raise "boom #{i}" if i == 1 }
    end

    assert_match(/boom/, error.message)
  end

  def test_an_error_stops_new_work_from_starting
    done = []
    lock = Mutex.new

    assert_raises(RuntimeError) do
      Judge::Pool.map(1..200, concurrency: 2) do |i|
        raise "stop" if i == 1

        lock.synchronize { done << i }
      end
    end

    assert_operator done.size, :<, 200, "the queue was not drained after the first error"
  end

  def test_every_item_is_visited_exactly_once
    seen = []
    lock = Mutex.new
    Judge::Pool.map(1..500, concurrency: 16) { |i| lock.synchronize { seen << i } }

    assert_equal (1..500).to_a, seen.sort
  end

  def test_an_interrupted_caller_stops_the_queue
    started = Queue.new
    ran = Queue.new
    assert_raises(Timeout::Error) do
      Timeout.timeout(0.15) do
        Judge::Pool.map(Array.new(40, 0.05), concurrency: 4) do |delay|
          started << 1
          sleep(delay)
          ran << 1
        end
      end
    end
    sleep 0.2

    assert_operator started.size, :<, 40
    assert_equal started.size, ran.size
  end

  def test_workers_close_their_connections_when_they_exit
    opened = Queue.new
    arrived = Queue.new
    Judge::Pool.map([1, 2, 3], concurrency: 3) do
      http = Net::HTTP.new("127.0.0.1", 1)
      http.define_singleton_method(:started?) { true }
      http.define_singleton_method(:finish) { opened << :closed }
      Thread.current[Judge::Client::CONNECTIONS_KEY] = { pid: Process.pid, connections: { key: http } }
      arrived << 1
      sleep 0.01 until arrived.size == 3
    end

    assert_equal 3, opened.size
  end

  def test_an_interrupted_caller_does_not_wait_for_calls_in_flight
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_raises(Timeout::Error) do
      Timeout.timeout(0.1) { Judge::Pool.map([0.6, 0.6], concurrency: 2) { |delay| sleep(delay) } }
    end
    waited = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator waited, :<, 0.4
  ensure
    Thread.list.select { |thread| thread.name == Judge::Pool::THREAD_NAME }.each(&:join)
  end

  def test_the_configured_concurrency_is_the_default
    Judge.config.concurrency = 2
    threads = Judge::Pool.map(Array.new(6), concurrency: nil) do
      sleep 0.01
      Thread.current
    end

    assert_equal 2, threads.uniq.size
  ensure
    Judge.config.concurrency = nil
  end

  def test_an_exception_that_is_not_a_standard_error_stops_the_queue
    ran = Queue.new
    assert_raises(NoMemoryError) do
      Judge::Pool.map(1..50, concurrency: 2) do |i|
        ran << i
        raise NoMemoryError, "boom" if i == 1

        sleep 0.01
      end
    end

    assert_operator ran.size, :<, 10
  end
end
