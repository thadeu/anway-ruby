# frozen_string_literal: true

require 'securerandom'

module Anway
  # Runs jobs until stop, or until the server sends terminate.
  #
  # After quiet, the runner stops fetching and stays alive. At a stop, running
  # jobs get `timeout` seconds to finish. Then Anway::Shutdown is raised in them,
  # and they get `cancel_grace` seconds to return. Jobs that still run then fail.
  class Runner
    BEAT_INTERVAL = 15
    ERROR_PAUSE = 1
    EMPTY_FETCH_MINIMUM = 0.2
    BACKTRACE_LINES = 30

    attr_reader :wid

    # The console shows the worker as hostname:pid with its tag. A nil
    # hostname uses the machine name. The server can change the thread count
    # in a BEAT reply, up to limit, such as the database pool size. autoscale,
    # as { max: n } or { min: n, max: n }, starts the worker with autoscale on.
    # subscriptions is a list of Worker::Subscription. The default is the
    # subscriptions of all registered job classes, read at run.
    def initialize(queues: ['default'], concurrency: 10, timeout: 25, cancel_grace: 5, labels: [],
                   hostname: nil, tag: nil, autoscale: nil, limit: nil, subscriptions: nil,
                   beat_interval: BEAT_INTERVAL, url: nil, logger: Anway.config.logger)
      @queues = Queues.new(queues)
      @subscriptions = subscriptions
      @concurrency = concurrency
      @limit = limit
      @timeout = timeout
      @cancel_grace = cancel_grace
      @beat_interval = beat_interval
      @logger = logger
      @wid = SecureRandom.hex(12)
      @fetching = Thread::Queue.new
      @stopped_beat = Thread::Queue.new
      @events_reader, @events_writer = IO.pipe
      @running = {}
      @lock = Mutex.new
      @processors = []
      @retiring = 0

      @client = Client.new(
        url || Anway.config.url,
        pool_size: concurrency + 1,
        timeout: Anway.config.timeout,
        tls: Anway.config.tls,
        wid: @wid,
        labels: ['ruby', *labels],
        identity: {
          hostname: hostname, tag: tag, queues: @queues.names, concurrency: concurrency,
          autoscale: autoscale, max_concurrency: limit
        }
      )
    end

    # Safe in a signal handler.
    def stop
      signal('s')
    end

    # Safe in a signal handler.
    def quiet
      signal('q')
    end

    # Safe in a signal handler.
    def dump
      signal('d')
    end

    # The first beat reports the threads, so the server can scale the worker
    # at once. The subscriptions go to the server before the first fetch.
    def run
      @client.heartbeat(nil, concurrency: @concurrency)

      subscribe_all

      @lock.synchronize { @processors = Array.new(@concurrency) { start_processor } }

      beat_thread = start_beat

      @logger.info("anway started queues=#{@queues.names.join(',')} concurrency=#{@concurrency}")

      wait_for_stop
      shutdown

      @stopped_beat.close
      beat_thread.join
    ensure
      @client.close
    end

    private

    def signal(letter)
      @events_writer.write_nonblock(letter, exception: false)
    end

    # SUBSCRIBE is idempotent, so each start sends all subscriptions. A
    # subscription queue that the worker does not fetch gets copies that wait.
    def subscribe_all
      (@subscriptions || Worker.subscriptions).each do |subscription|
        @client.subscribe(
          subscription.topic,
          queue: subscription.queue,
          jobtype: subscription.jobtype,
          retry: subscription.retry,
          reserve_for: subscription.reserve_for
        )

        @logger.info("anway subscribed topic=#{subscription.topic} queue=#{subscription.queue} jobtype=#{subscription.jobtype}")

        next if @queues.names.include?(subscription.queue)

        @logger.warn("anway does not fetch queue #{subscription.queue}, so the events of topic #{subscription.topic} wait there. Add the queue to queues.")
      end
    end

    def wait_for_stop
      loop do
        @events_reader.wait_readable

        case @events_reader.read_nonblock(1)
        when 's' then return
        when 'q' then stop_fetching
        when 'd' then dump_threads
        end
      end
    end

    def dump_threads
      Thread.list.each { |thread| @logger.info("#{thread.inspect}\n#{thread.backtrace&.first(10)&.join("\n")}") }
    end

    def stop_fetching
      @fetching.close
    end

    def fetching?
      !@fetching.closed?
    end

    def pause(seconds)
      @fetching.pop(timeout: seconds)
    end

    def start_beat
      Thread.new do
        state = nil

        until @stopped_beat.closed?
          @stopped_beat.pop(timeout: @beat_interval)

          break if @stopped_beat.closed?

          state = beat(state)
        end
      end
    end

    def beat(state)
      reply = @client.heartbeat(state, concurrency: @concurrency)

      # A new count goes to the server at once, not at the next beat, so the
      # console shows the threads that run, and the next autoscale step starts
      # from them.
      @client.heartbeat(state, concurrency: @concurrency) if reply.concurrency && resize(reply.concurrency)

      case reply.state
      when 'quiet'
        quiet

        'quiet'
      when 'terminate'
        stop

        state
      else
        state
      end
    rescue Error => e
      @logger.warn("beat failed: #{e.message}")

      state
    end

    # Starts threads, or asks threads to stop after their job. A stop that is
    # still pending is canceled first, so the count is right at once. Returns
    # true when the count changed.
    def resize(size)
      return unless size.is_a?(Integer) && size.positive? && fetching?

      size = [size, @limit].min if @limit

      @lock.synchronize do
        change = size - @concurrency

        return if change.zero?

        if change.positive?
          kept = [@retiring, change].min

          @retiring -= kept
          @client.grow_pool(size + 1)
          @processors.select!(&:alive?)
          (change - kept).times { @processors << start_processor }
        else
          @retiring -= change
        end

        @concurrency = size
      end

      @logger.info("anway threads=#{size}")

      true
    end

    def retire?
      @lock.synchronize do
        return false unless @retiring.positive?

        @retiring -= 1

        true
      end
    end

    # Shutdown stays pending outside perform, so it cannot break a report.
    def start_processor
      Thread.new do
        Thread.handle_interrupt(Shutdown => :never) { process_loop }
      end
    end

    # A fetch in progress is not canceled, because its reply can hold a job.
    def process_loop
      while fetching? && !retire?
        started = monotonic
        job = fetch_next

        if job
          process(job)
        elsif monotonic - started < EMPTY_FETCH_MINIMUM
          pause(EMPTY_FETCH_MINIMUM)
        end
      end
    end

    def fetch_next
      @client.fetch(*@queues.order)
    rescue Error => e
      @logger.warn("fetch failed: #{e.message}")
      pause(ERROR_PAUSE)

      nil
    end

    def process(job)
      @lock.synchronize { @running[job.jid] = { job: job, thread: Thread.current } }

      error = perform(job)

      return unless claim(job.jid)

      report(job, error)
    end

    def perform(job)
      Thread.handle_interrupt(Shutdown => :immediate) { Executor.call(job) }

      nil
    rescue Exception => e # rubocop:disable Lint/RescueException
      notify_error(e, job) unless e.is_a?(Shutdown)

      e
    end

    def notify_error(error, job)
      @logger.warn("job failed jid=#{job.jid} jobtype=#{job.type} error=#{error.class}: #{error.message}")

      Anway.config.error_handlers.each { |handler| handler.call(error, job) }
    rescue StandardError => e
      @logger.error("error handler failed: #{e.message}")
    end

    def claim(jid)
      @lock.synchronize { !@running.delete(jid).nil? }
    end

    def report(job, error)
      if error
        @client.fail(
          job.jid,
          errtype: error.class.name,
          message: error.message,
          backtrace: error.backtrace&.first(BACKTRACE_LINES) || []
        )
      else
        @client.ack(job.jid)
      end
    rescue Error => e
      @logger.warn("job report failed, the reservation will expire jid=#{job.jid}: #{e.message}")
    end

    def shutdown
      stop_fetching if fetching?

      return if join_processors(@timeout)

      running.each { |entry| entry[:thread].raise(Shutdown, 'the worker is stopping') }

      return if join_processors(@cancel_grace)

      running.each { |entry| abandon(entry) }
    end

    def running
      @lock.synchronize { @running.values }
    end

    def abandon(entry)
      job = entry[:job]

      return unless claim(job.jid)

      @logger.warn("job did not stop jid=#{job.jid} jobtype=#{job.type}")

      entry[:thread].kill

      report(job, Shutdown.new('the worker stopped before the job finished'))
    end

    def join_processors(limit)
      deadline = monotonic + limit

      threads = @lock.synchronize { @processors.dup }

      threads.all? { |thread| thread.join([deadline - monotonic, 0].max) }
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
