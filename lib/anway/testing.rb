# frozen_string_literal: true

require 'anway'

module Anway
  # Test modes for apps. No server is necessary.
  #
  #   Anway::Testing.fake!    keeps pushed jobs in a list
  #   Anway::Testing.inline!  runs each job at push
  #   Anway::Testing.disable! uses the real client
  module Testing
    @mode = nil
    @jobs = []

    class << self
      attr_reader :jobs, :mode

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
      end

      def enqueue(job)
        copy = Job.from_hash(JSON.parse(JSON.generate(job.to_h)))

        @mode == :inline ? Executor.call(copy) : @jobs << copy

        job.jid
      end

      # Runs and removes all fake jobs. Jobs that they push also run.
      def drain
        Executor.call(@jobs.shift) until @jobs.empty?
      end
    end
  end
end
