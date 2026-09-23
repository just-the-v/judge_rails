# frozen_string_literal: true

module Judge
  module Pool
    DEFAULT_CONCURRENCY = 8

    module_function

    def map(items, concurrency: DEFAULT_CONCURRENCY, &work)
      list = items.to_a
      return [] if list.empty?
      return list.map(&work) if concurrency.to_i <= 1 || list.one?

      fan_out(list, [concurrency.to_i, list.size].min, &work)
    end

    def fan_out(list, workers, &work)
      queue = Queue.new
      list.each_with_index { |item, index| queue << [index, item] }
      results = Array.new(list.size)
      errors = []
      lock = Mutex.new

      threads = Array.new(workers) do
        spawn do
          while (job = pop(queue))
            index, item = job
            begin
              value = work.call(item)
              lock.synchronize { results[index] = value }
            rescue StandardError => e
              lock.synchronize { errors << e }
              drain(queue)
            end
          end
        end
      end
      wait(threads)

      raise errors.first unless errors.empty?

      results
    ensure
      drain(queue) if queue
      wait(threads) if threads
    end

    def spawn(&body)
      tags = log_tags
      thread = Thread.new do
        in_executor { tagged(tags, &body) }
      ensure
        Client.close_thread_connections
      end
      thread.report_on_exception = false
      thread
    end

    def wait(threads)
      if defined?(::ActiveSupport::Dependencies.interlock)
        ::ActiveSupport::Dependencies.interlock.permit_concurrent_loads { threads.each(&:join) }
      else
        threads.each(&:join)
      end
    end

    def in_executor(&)
      executor = defined?(::Rails.application.executor) && ::Rails.application&.executor
      executor ? executor.wrap(&) : yield
    end

    def log_tags
      formatter = Judge.config.logger.respond_to?(:formatter) && Judge.config.logger.formatter
      formatter.respond_to?(:current_tags) ? formatter.current_tags.dup : []
    end

    def tagged(tags, &)
      logger = Judge.config.logger
      tags.empty? || !logger.respond_to?(:tagged) ? yield : logger.tagged(*tags, &)
    end

    def pop(queue)
      queue.pop(true)
    rescue ThreadError
      nil
    end

    def drain(queue)
      loop { queue.pop(true) }
    rescue ThreadError
      nil
    end
  end
end
