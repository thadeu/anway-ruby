# frozen_string_literal: true

module Anway
  # Cron entries that an app declares. The worker sends them with SCHEDULE
  # when it starts, and the server keeps them for the tag of the app. An entry
  # has the format of a cron entry in the conf.d of the server:
  #
  #   { 'schedule' => '0 0 * * *',
  #     'job' => { 'type' => 'credits.refill', 'queue' => 'default', 'retry' => 3,
  #                'args' => [], 'reserve_for' => 0, 'custom' => {} } }
  #
  # Only schedule and job.type are required. job.event is the input contract
  # name of job.type, and goes out as type.
  module Cron
    module_function

    # The entry with string keys. A value that is not a hash with a schedule
    # and a job raises ArgumentError. The server checks the rest.
    def entry(value)
      raise ArgumentError, "a cron entry must be a hash with schedule and job, not #{value.inspect}" unless value.is_a?(Hash)

      entry = stringify(value)
      job = entry['job']

      raise ArgumentError, "the cron entry #{entry['schedule'].inspect} needs a job hash" unless job.is_a?(Hash)

      job['type'] = job.delete('event').to_s if job.key?('event') && !job.key?('type')

      entry
    end

    def entries(values)
      raise ArgumentError, "cron must be a list of entries, not #{values.inspect}" unless values.is_a?(Array)

      values.map { |value| entry(value) }
    end

    def stringify(value)
      case value
      when Hash then value.to_h { |key, item| [key.to_s, stringify(item)] }
      when Array then value.map { |item| stringify(item) }
      else value
      end
    end
  end
end
