# frozen_string_literal: true

require 'time'

module Anway
  # The input contract: the keys that an app uses to declare or push a job.
  # This module is the only place that turns them into the fields of a job on
  # the wire. anway_options, set, perform_*, Anway.push, and Anway::Job.new
  # all use it. See "Input contract" in docs/dev/clients.md of the server.
  #
  #   event        jobtype (positional in Anway::Job.new)
  #   queue, retry, reserve_for, backtrace, at
  #                the field with the same name
  #   unique_for, unique_until, expires_in, expires_at, track, on_dead
  #                custom, with expires_at as RFC 3339, track true as 1, and
  #                on_dead { event:, queue: } as { "jobtype", "queue" }
  #   custom       custom, for the keys of the app. The keys above win.
  #   topics       one SUBSCRIBE for each topic (a declaration only)
  module Options
    # Keys with a wire field of the same name.
    FIELDS = %i[queue retry reserve_for backtrace at].freeze

    # Keys that go to custom.
    CUSTOM = %i[unique_for unique_until expires_in expires_at track on_dead].freeze

    # The keys of a push: Anway::Job.new, Anway.push, and set.
    PUSH = [*FIELDS, *CUSTOM, :custom].freeze

    # The keys of a declaration: anway_options. at is only for a push, and
    # topics only for a declaration.
    DECLARATION = [:event, *(PUSH - [:at]), :topics].freeze

    ON_DEAD = %i[event queue].freeze

    module_function

    def check!(options, allowed)
      unknown = options.keys - allowed

      return if unknown.empty?

      raise ArgumentError, "unknown options: #{unknown.join(', ')}"
    end

    # Merges option sets in order. A single value from a later set wins.
    # topics add up in order, with no duplicates. custom hashes merge, and a
    # later key wins.
    def merge(*sets)
      sets.each_with_object({}) do |set, merged|
        set.each do |key, value|
          merged[key] =
            case key
            when :topics then (merged[:topics] || []) | Array(value).map(&:to_s)
            when :custom then (merged[:custom] || {}).merge(stringify(value))
            else value
            end
        end
      end
    end

    # Turns the keys of a push into wire fields, with string keys. A nil
    # value sends no field.
    def wire(options)
      fields = FIELDS.to_h { |key| [key.to_s, field(key, options[key])] }

      contract = CUSTOM.to_h { |key| [key.to_s, custom_field(key, options[key])] }.compact
      custom = stringify(options[:custom]).merge(contract)

      fields['custom'] = custom unless custom.empty?

      fields.compact
    end

    # A time as RFC 3339, in UTC. A string goes as it is.
    def time(value)
      return value if value.nil? || value.is_a?(String)

      value.to_time.utc.iso8601(9)
    end

    def field(key, value)
      case key
      when :queue then value&.to_s
      when :at then time(value)
      else value
      end
    end

    def custom_field(key, value)
      case key
      when :unique_until then value&.to_s
      when :expires_at then time(value)
      when :track then track(value)
      when :on_dead then on_dead(value)
      else value
      end
    end

    def track(value)
      case value
      when true then 1
      when false then nil
      else value
      end
    end

    def on_dead(value)
      return nil if value.nil?

      hook = value.to_h.transform_keys(&:to_sym)

      check!(hook, ON_DEAD)

      raise ArgumentError, 'on_dead needs an event' if hook[:event].to_s.empty?

      { 'jobtype' => hook[:event].to_s, 'queue' => hook[:queue]&.to_s }.compact
    end

    def stringify(hash)
      (hash || {}).transform_keys(&:to_s)
    end
  end
end
