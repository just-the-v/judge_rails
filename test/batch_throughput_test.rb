# frozen_string_literal: true

require "test_helper"
require "judge/batch"

# Arm 4 of BENCHMARK.md, in the small. It proves the pool overlaps requests and that batching
# cuts the request count, against a real local HTTP server. The full arm 4 (250 rows at the
# measured 0.300s latency) lives in bin/bench_batch, because a faithful run takes 75 seconds
# and that does not belong in a test suite.
class BatchThroughputTest < Minitest::Test
  LATENCY = 0.1

  def setup
    @server = FakeJev.start
    Judge.reset_config!
    Judge.configure do |c|
      c.api_key = "test-key"
      c.base_url = @server.url
    end
    @question = Judge.noul("Is this urgent?")
  end

  def teardown
    @server&.stop
    Judge.reset_config!
  end

  def items(count)
    (0...count).to_h { |i| [:"item#{i}", "ticket body number #{i}"] }
  end

  def elapsed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  def test_batching_cuts_the_request_count_against_a_real_server
    judged = Judge::Batch.judge(items(40), @question, rows: 20, concurrency: 2)

    assert_equal 40, judged.size
    assert_equal 2, @server.request_count
    assert(judged.values.all? { |result| result.value.between?(0.0, 1.0) })
  end

  def test_the_pool_overlaps_requests_instead_of_queueing_them
    @server.latency = LATENCY

    # 8 batches of one row each. Serial would cost 8 x LATENCY; the pool should land near one.
    duration = elapsed { Judge::Batch.judge(items(8), @question, rows: 1, concurrency: 8) }

    assert_equal 8, @server.request_count
    assert_operator duration, :<, LATENCY * 4,
                    "8 requests at #{LATENCY}s took #{duration.round(3)}s, so they did not overlap"
  end

  def test_one_batch_uses_one_connection_and_one_request
    @server.latency = LATENCY

    duration = elapsed { Judge::Batch.judge(items(20), @question, rows: 20, concurrency: 8) }

    assert_equal 1, @server.request_count
    assert_operator duration, :<, LATENCY * 3
  end

  def test_a_batched_payload_carries_every_row_in_one_state
    Judge::Batch.judge(items(20), @question, rows: 20, concurrency: 1)

    payload = @server.requests.fetch(0)
    state = JSON.parse(payload.fetch("state"))

    assert_equal 20, state.fetch("rows").size
    assert_equal 20, payload.fetch("questions").size
    assert_equal((0...20).to_a, state.fetch("rows").map { |row| row.fetch("id") })
  end

  def test_a_transport_failure_inside_the_pool_reaches_the_caller
    @server.always_fail(status: 401)

    assert_raises(Judge::AuthenticationError) do
      Judge::Batch.judge(items(20), @question, rows: 5, concurrency: 4)
    end
  end

  def test_a_retryable_failure_is_retried_inside_the_worker
    @server.fail_next(1, status: 500)
    judged = Judge::Batch.judge(items(10), @question, rows: 10, concurrency: 1)

    assert_equal 10, judged.size
    assert_equal 2, @server.request_count
  end
end
