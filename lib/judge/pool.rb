# frozen_string_literal: true

module Judge
  module Pool
    DEFAULT_CONCURRENCY = 8
    THREAD_NAME = "judge-pool"

    @worker_exit_hooks = []

    class << self
      def map(items, concurrency: nil, &work)
        list = items.to_a
        return [] if list.empty?

        workers = (concurrency || Judge.config.concurrency || DEFAULT_CONCURRENCY).to_i
        return list.map(&work) if workers <= 1 || list.one?

        fan_out(list, [workers, list.size].min, &work)
      end

      def on_worker_exit(&hook)
        @worker_exit_hooks << hook unless @worker_exit_hooks.include?(hook)
        hook
      end

      private

      def fan_out(list, workers, &work)
        queue = Queue.new
        list.each_with_index { |item, index| queue << [index, item] }
        results = Array.new(list.size)
        errors = []
        lock = Mutex.new

        threads = Array.new(workers) do
          spawn(queue) do
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
        threads.each(&:join)

        raise errors.first unless errors.empty?

        results
      ensure
        drain(queue) if queue
      end

      def spawn(queue, &body)
        tags = log_tags
        thread = Thread.new do
          finished = false
          tagged(tags, &body)
          finished = true
        ensure
          drain(queue) unless finished
          @worker_exit_hooks.each(&:call)
        end
        thread.name = THREAD_NAME
        thread.report_on_exception = false
        thread
      end

      def log_tags
        logger = Judge.config.logger
        formatter = logger.respond_to?(:formatter) && logger.formatter
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
end
