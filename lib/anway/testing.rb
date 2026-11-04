# frozen_string_literal: true

require 'anway'

module Anway
  # Test modes for apps. No server is necessary.
  #
  #   Anway::Testing.fake!    keeps pushed jobs and published events in lists
  #   Anway::Testing.inline!  runs each job at push, and each event in the
  #                           subscribed classes of the app at publish
  #   Anway::Testing.disable! uses the real client
  module Testing
    @mode = nil
    @jobs = []
    @events = []

    class << self
      attr_reader :jobs, :events, :mode

      def fake!
        @mode = :fake
      end

      def inline!
        @mode = :inline
      end

      def disable!
        @mode = nil
      end

      def clear
        @jobs.clear
        @events.clear
      end

      def enqueue(job)
        copy = Job.from_hash(JSON.parse(JSON.generate(job.to_h)))

        @mode == :inline ? Executor.call(copy) : @jobs << copy

        job.jid
      end

      # Keeps or runs each job as a single push does. No job is refused, so
      # the result is {}.
      def push_bulk(jobs)
        jobs.each { |job| enqueue(job) }

        {}
      end

      # Keeps the event as the PUBLISH payload, with string keys. jobs is the
      # number of subscriptions in the job classes of the app. There is no
      # duplicate check.
      def publish(topic, args = [], id: nil, unique_for: nil, custom: nil)
        event = { 'topic' => topic, 'args' => args, 'id' => id, 'unique_for' => unique_for, 'custom' => custom }
        copy = JSON.parse(JSON.generate(event.compact))

        event_id = id || "evt-#{SecureRandom.hex(12)}"
        subscriptions = Worker.subscriptions.select { |subscription| subscription.topic == topic.to_s }

        @events << copy

        subscriptions.each { |subscription| Executor.call(event_job(subscription, copy, event_id)) } if @mode == :inline

        Client::Published.new(event: event_id, jobs: subscriptions.size, duplicate: false)
      end

      # Runs and removes all fake jobs. Jobs that they push also run.
      def drain
        Executor.call(@jobs.shift) until @jobs.empty?
      end

      private

      # The copy that the server makes for one subscription.
      def event_job(subscription, event, event_id)
        custom = (event['custom'] || {}).merge('topic' => subscription.topic, 'event' => event_id)

        Job.new(
          subscription.event, event['args'],
          queue: subscription.queue, retry: subscription.retry, reserve_for: subscription.reserve_for, custom: custom
        )
      end
    end
  end
end
