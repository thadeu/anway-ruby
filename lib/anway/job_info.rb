# frozen_string_literal: true

require 'time'

module Anway
  # JobInfo is a read-only view of one job on the server, from the HTTP API
  # (Anway.job, Anway.jobs, `anway job`).
  #
  # state is waiting, working, retries, scheduled or dead. wrapped is the
  # Active Job class when the job type is the Active Job wrapper. error has
  # class, message and backtrace when the job failed.
  JobInfo = Data.define(
    :jid, :type, :wrapped, :queue, :state, :args, :custom, :retry_count, :retry_max,
    :next_at, :enqueued_at, :started_at, :worker, :error
  ) do
    def self.from_api(view, set: nil)
      custom = view['custom'] || {}
      failure = view['failure']

      new(
        jid: view['jid'],
        type: view['jobtype'],
        wrapped: custom['wrapped'],
        queue: view['queue'],
        state: set || state_of(view['state']),
        args: view['args'] || [],
        custom: custom,
        retry_count: failure ? failure['retry_count'].to_i + 1 : 0,
        retry_max: view['retry'],
        next_at: time(failure&.dig('next_at')) || (%w[scheduled retries].include?(set) ? time(view['at']) : nil),
        enqueued_at: time(view['enqueued_at']),
        started_at: time(view['started_at']),
        worker: view['worker'],
        error: failure && { class: failure['errtype'], message: failure['message'], backtrace: failure['backtrace'] || [] }
      )
    end

    def self.state_of(state) = (state == 'queues') ? 'waiting' : state

    def self.time(value)
      Time.parse(value.to_s) if value && !value.to_s.empty?
    end

    # The class to show: the Active Job class, else the job type.
    def name = wrapped || type
  end
end
