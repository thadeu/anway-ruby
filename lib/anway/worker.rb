# frozen_string_literal: true

module Anway
  # Makes a class a job:
  #
  #   class WelcomeJob
  #     include Anway::Worker
  #
  #     anway_options event: 'email.welcome', retry: 5
  #     anway_options topics: %w[user.created], queue: 'mailers'
  #
  #     def perform(user_id); end
  #   end
  #
  #   WelcomeJob.perform_async(42)
  #   WelcomeJob.set(queue: 'low', unique_for: 60).perform_async(42)
  #   WelcomeJob.perform_bulk([[1], [2], [3]])
  #
  # The keys are the input contract (Anway::Options). The event is the job
  # type on the wire, and the default is the class name. Each topic makes one
  # subscription, which the worker sends when it starts.
  module Worker
    DEFAULT_BACKTRACE = 30

    # One topic, queue, and event. retry and reserve_for are the options of
    # each copy.
    Subscription = Data.define(:topic, :queue, :event, :retry, :reserve_for)

    # A subclass does not inherit these keys.
    OWN_KEYS = %i[event topics].freeze

    @registry = {}
    @lock = Mutex.new

    class << self
      def included(base)
        base.extend(ClassMethods)

        register(base) if base.name
      end

      # Each event has one class. A class with the same name replaces the old
      # one, as after a code reload. Another class with the same event raises
      # ArgumentError.
      def register(klass, old_event: nil)
        event = klass.anway_options[:event]

        @lock.synchronize do
          current = @registry[event]

          if current && !current.equal?(klass) && current.name != klass.name
            raise ArgumentError, "event #{event.inspect} already has the class #{current.name}, so #{klass.name} cannot use it"
          end

          @registry.delete(old_event) if old_event && @registry[old_event].equal?(klass)
          @registry[event] = klass
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

      # Only registered classes run. The event comes from the network, so it
      # never becomes a constant lookup. The lookup by the class name below
      # uses a registered name, and returns the newest class after a reload.
      def find(event)
        klass = @lock.synchronize { @registry[event] }

        raise UnknownJob, "no handler for event #{event.inspect}" unless klass

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

      # With keys, adds one option set to the class. The keys are
      # Anway::Options::DECLARATION, and an unknown key raises ArgumentError.
      #
      # Without keys, returns the options of the class: the options of the
      # parent class without event and topics, then each set in call order.
      # event and topics are always in the result.
      def anway_options(**options)
        return declared_options if options.empty?

        Options.check!(options, Options::DECLARATION)

        # Translates the set now, so that a bad value, such as an on_dead
        # without an event, fails when the class loads.
        Options.wire(options.except(*OWN_KEYS))

        options = options.merge(event: event_name(options[:event])) if options.key?(:event)
        old_event = declared_options[:event]

        (@anway_option_sets ||= []) << options.freeze

        register_event(old_event) if options.key?(:event)

        declared_options
      end

      # One subscription for each topic, with the event, queue, retry, and
      # reserve_for of the class. Without a queue, the copies go to default.
      def subscriptions
        options = declared_options
        queue = (options[:queue] || 'default').to_s

        options[:topics].map do |topic|
          Subscription.new(
            topic: topic,
            queue: queue,
            event: options[:event],
            retry: options[:retry],
            reserve_for: options[:reserve_for]
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

      # Changes the options for one push, with the push keys of
      # Anway::Options::PUSH: WelcomeJob.set(queue: 'low').perform_async(1)
      def set(**options)
        Options.check!(options, Options::PUSH)

        Setter.new(self, options)
      end

      # Pushes one job for each item, and each item is the args of one job:
      # WelcomeJob.perform_bulk([[1], [2], [3]]). All jobs are built before
      # the first send, so a bad item sends no job. Each Client::MAX_BULK jobs
      # go in one PUSHB. Returns the reason for each refused job by jid, or {}
      # when all jobs are in. Inside a database transaction, the push waits
      # for the commit and returns nil.
      def perform_bulk(args_list)
        bulk_with(args_list, {})
      end

      def enqueue_with(args, options)
        event, push = push_options(options)

        Anway.enqueue(Job.new(event, args, **push))
      end

      def bulk_with(args_list, options)
        raise ArgumentError, "perform_bulk needs an array of args: #{args_list.inspect}" unless args_list.is_a?(Array)

        event, push = push_options(options)

        jobs = args_list.map do |args|
          Job.validate_args!(args)

          Job.new(event, args, **push)
        end

        Anway.push_bulk(jobs)
      end

      private

      # The event, and the push keys: the options of the class, then the
      # options of the push, merge with the same rules as two anway_options
      # calls.
      def push_options(options)
        declared = declared_options
        push = Options.merge({ backtrace: DEFAULT_BACKTRACE }, declared.except(*OWN_KEYS), options)

        [declared[:event], push]
      end

      def declared_options
        parent = superclass.respond_to?(:anway_options) ? superclass.anway_options.except(*OWN_KEYS) : {}

        Options.merge({ event: name, topics: [] }, parent, *@anway_option_sets).freeze
      end

      # A set with an event that another class has does not stay.
      def register_event(old_event)
        return unless name

        Worker.register(self, old_event: old_event)
      rescue ArgumentError
        @anway_option_sets.pop

        raise
      end

      def event_name(value)
        event = value.to_s

        raise ArgumentError, 'event must not be empty' if event.empty?

        event
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

      def perform_bulk(args_list)
        @klass.bulk_with(args_list, @options)
      end
    end
  end
end
