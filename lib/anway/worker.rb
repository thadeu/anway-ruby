# frozen_string_literal: true

module Anway
  # Makes a class a job:
  #
  #   class WelcomeJob
  #     include Anway::Worker
  #
  #     job_options queue: 'mailers', retry: 5
  #
  #     def perform(user_id); end
  #   end
  #
  #   WelcomeJob.perform_async(42)
  #
  # A class can also run the events of a topic:
  #
  #   class BroadcastMessage
  #     include Anway::Worker
  #
  #     subscribe 'chat.message', queue: 'realtime'
  #
  #     def perform(message); end
  #   end
  module Worker
    DEFAULT_BACKTRACE = 30
    SUBSCRIBE_OPTIONS = %i[retry reserve_for].freeze

    # One topic, queue, and job type. retry and reserve_for are the options of
    # each copy.
    Subscription = Data.define(:topic, :queue, :jobtype, :retry, :reserve_for)

    @registry = {}
    @lock = Mutex.new

    class << self
      def included(base)
        base.extend(ClassMethods)

        register(base) if base.name
      end

      def register(klass, old_type: nil)
        @lock.synchronize do
          @registry.delete(old_type) if old_type
          @registry[klass.job_type] = klass
        end
      end

      def classes
        @lock.synchronize { @registry.values }
      end

      # The subscriptions of all registered classes. A worker sends them with
      # SUBSCRIBE when it starts.
      def subscriptions
        classes.flat_map(&:subscriptions).uniq
      end

      # Only registered classes run. The job type comes from the network, so it
      # never becomes a constant lookup. The lookup by the class name below
      # uses a registered name, and returns the newest class after a reload.
      def find(type)
        klass = @lock.synchronize { @registry[type] }

        raise UnknownJob, "no handler for job type #{type.inspect}" unless klass

        klass.name ? Object.const_get(klass.name) : klass
      end
    end

    attr_accessor :job

    def jid
      job&.jid
    end

    # Updates the progress of a tracked job.
    def track(percent: nil, desc: nil, reserve_until: nil)
      Anway.client.track_set(jid, percent: percent, desc: desc, reserve_until: reserve_until)
    end

    module ClassMethods
      def inherited(subclass)
        super

        Worker.register(subclass) if subclass.name
      end

      def job_type(name = nil)
        return @job_type || self.name unless name

        old_type = job_type
        @job_type = name

        Worker.register(self, old_type: old_type)
      end

      def job_options(options = nil)
        inherited_options = superclass.respond_to?(:job_options) ? superclass.job_options : {}

        @job_options = (@job_options || {}).merge(options) if options

        inherited_options.merge(@job_options || {})
      end

      # Runs each event of the topic in this class. The job type is the job
      # type of the class. queue, retry, and reserve_for have the job_options
      # of the class as defaults, read when the worker starts. A subclass does
      # not get the subscriptions of its parent.
      def subscribe(topic, queue: nil, **options)
        unknown = options.keys - SUBSCRIBE_OPTIONS

        raise ArgumentError, "unknown subscribe options: #{unknown.join(', ')}" if unknown.any?

        entry = { topic: topic.to_s, queue: queue&.to_s, **options }

        @subscriptions ||= []
        @subscriptions << entry unless @subscriptions.include?(entry)
      end

      def subscriptions
        defaults = job_options

        (@subscriptions || []).map do |entry|
          Subscription.new(
            topic: entry[:topic],
            queue: entry[:queue] || defaults[:queue]&.to_s || 'default',
            jobtype: job_type,
            retry: entry.fetch(:retry, defaults[:retry]),
            reserve_for: entry.fetch(:reserve_for, defaults[:reserve_for])
          )
        end
      end

      def perform_async(*args)
        enqueue_with(args, {})
      end

      def perform_at(time, *args)
        enqueue_with(args, { at: time })
      end

      def perform_in(seconds, *args)
        enqueue_with(args, { at: Time.now + seconds.to_f })
      end

      # Changes the options for one push: WelcomeJob.set(queue: 'low').perform_async(1)
      def set(**options)
        Setter.new(self, options)
      end

      def enqueue_with(args, options)
        Anway.enqueue(Job.new(job_type, args, backtrace: DEFAULT_BACKTRACE, **job_options, **options))
      end
    end

    class Setter
      def initialize(klass, options)
        @klass = klass
        @options = options
      end

      def perform_async(*args)
        @klass.enqueue_with(args, @options)
      end

      def perform_at(time, *args)
        @klass.enqueue_with(args, @options.merge(at: time))
      end

      def perform_in(seconds, *args)
        @klass.enqueue_with(args, @options.merge(at: Time.now + seconds.to_f))
      end
    end
  end
end
