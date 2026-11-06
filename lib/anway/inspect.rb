# frozen_string_literal: true

module Anway
  # Inspect reads the jobs on the server for people: `anway jobs`,
  # Anway.jobs and Anway.job. With Anway::Testing.fake!, it reads the fake
  # jobs instead, so app tests use the same calls.
  module Inspect
    SETS = %w[waiting working retries scheduled dead].freeze

    # Summary is one line for each set: how many jobs, and the most common
    # job type, worker and error in its first page.
    Summary = Data.define(:sets) do
      def [](set) = sets.find { |line| line[:set] == set.to_s }

      def to_h = { sets: sets }
    end

    # Jobs reads a set page by page, only as far as it is read, so
    # `first(5)` asks for one page. type matches a part of the job type or
    # of the Active Job class.
    class Jobs
      include Enumerable

      def initialize(api, set:, type: nil, queue: nil, page: 50)
        @api = api
        @set = set.to_s
        @type = type&.to_s
        @queue = queue
        @page = page
      end

      def each
        return enum_for(:each) unless block_given?

        cursor = ''

        loop do
          reply = @api.jobs(set: @set, cursor: cursor, limit: @page, queue: @queue)

          reply.fetch('jobs', []).each do |view|
            info = JobInfo.from_api(view, set: set_name)

            yield info if match?(info)
          end

          cursor = reply['next_cursor'].to_s

          break if cursor.empty?
        end
      end

      private

      def set_name = @set.start_with?('queue:') ? 'waiting' : @set

      def match?(info)
        @type.nil? || info.type.to_s.include?(@type) || info.wrapped.to_s.include?(@type)
      end
    end

    module_function

    def summary(api)
      counts = api.overview.fetch('states', {})

      sets = SETS.map do |set|
        count = counts[set].to_i
        sample = count.zero? ? [] : Jobs.new(api, set: set, page: 50).first(50)

        { set: set, count: count, top: top(sample, &:name), worker: top(sample, &:worker), error: top(sample) { |info| info.error && "#{info.error[:class]}: #{info.error[:message]}" }, oldest: sample.filter_map(&:enqueued_at).min }
      end

      Summary.new(sets: sets)
    end

    def top(infos)
      counts = infos.filter_map { |info| yield(info) }.tally

      return nil if counts.empty?

      value, count = counts.max_by { |_, n| n }

      { value: value, count: count }
    end

    # The fake jobs, as JobInfo in the waiting set.
    def fake(jobs)
      jobs.map do |job|
        JobInfo.from_api({ 'jid' => job.jid, 'jobtype' => job.type, 'queue' => job.queue || 'default', 'args' => job.args, 'custom' => job.custom, 'enqueued_at' => job.enqueued_at }, set: 'waiting')
      end
    end
  end
end
