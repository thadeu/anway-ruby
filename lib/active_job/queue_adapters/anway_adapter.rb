# frozen_string_literal: true

require 'active_job'
require 'anway'

module Anway
  # Runs serialized ActiveJob payloads.
  class ActiveJobWrapper
    include Anway::Worker

    job_type 'ActiveJob'

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

      private

      # Each push has a new id. A retry_on attempt keeps its job_id while the
      # first attempt is still reserved, and the server rejects a repeated id.
      def push(job, options)
        options = options.merge(queue: job.queue_name, backtrace: BACKTRACE)

        # retry_on owns the attempts, so its final error goes to the dead set.
        options[:retry] = DEAD_SET if job.class.anway_retry_on

        pushed = Anway::Job.new('ActiveJob', [job.serialize.as_json], **options)

        job.provider_job_id = pushed.jid

        Anway.enqueue(pushed)
      end
    end
  end
end
