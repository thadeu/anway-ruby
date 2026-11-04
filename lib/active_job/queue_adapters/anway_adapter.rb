# frozen_string_literal: true

require 'active_job'
require 'anway'

module Anway
  # Runs serialized ActiveJob payloads.
  class ActiveJobWrapper
    include Anway::Worker

    EVENT = 'ActiveJob'

    anway_options event: EVENT

    def perform(data)
      ActiveJob::Base.execute(data)
    end
  end

  # Records the use of retry_on, because rescue_handlers also holds rescue_from.
  module ActiveJobRetries
    def retry_on(...)
      self.anway_retry_on = true

      super
    end
  end
end

ActiveSupport.on_load(:active_job) do
  class_attribute :anway_retry_on, default: false
  singleton_class.prepend(Anway::ActiveJobRetries)
end

module ActiveJob
  module QueueAdapters
    class AnwayAdapter < AbstractAdapter
      BACKTRACE = 30
      DEAD_SET = -1

      def enqueue(job)
        push(job, {})
      end

      def enqueue_at(job, timestamp)
        push(job, { at: Time.at(timestamp) })
      end

      # ActiveJob.perform_all_later calls this. Jobs of all classes and queues
      # go together, with one PUSHB for each 1,000 jobs, and a scheduled job
      # gets its at. Sets successfully_enqueued on each job, and enqueue_error
      # on a refused job. Returns the number of jobs in. Inside a database
      # transaction, the push waits for the commit, and each job counts as in,
      # as perform_later does.
      def enqueue_all(jobs)
        pushed = jobs.map { |job| [job, build(job, scheduled(job))] }
        failures = Anway.push_bulk(pushed.map(&:last)) || {}

        pushed.each do |job, wire|
          reason = failures[wire.jid]

          job.provider_job_id = wire.jid
          job.successfully_enqueued = reason.nil?
          job.enqueue_error = reason && ActiveJob::EnqueueError.new(reason)
        end

        jobs.count(&:successfully_enqueued?)
      end

      private

      def scheduled(job)
        job.scheduled_at ? { at: Time.at(job.scheduled_at.to_f) } : {}
      end

      # Each push has a new id. A retry_on attempt keeps its job_id while the
      # first attempt is still reserved, and the server rejects a repeated id.
      # custom.wrapped names the job class, so that the console shows it, as
      # Sidekiq does. The options are the push keys of the input contract.
      def push(job, options)
        pushed = build(job, options)

        job.provider_job_id = pushed.jid

        Anway.enqueue(pushed)
      end

      def build(job, options)
        options = options.merge(queue: job.queue_name, backtrace: BACKTRACE, custom: { 'wrapped' => job.class.name })

        # retry_on owns the attempts, so its final error goes to the dead set.
        options[:retry] = DEAD_SET if job.class.anway_retry_on

        Anway::Job.new(
          Anway::ActiveJobWrapper::EVENT,
          [job.serialize.as_json],
          **options
        )
      end
    end
  end
end
