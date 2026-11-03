# frozen_string_literal: true

require 'json'
require 'securerandom'
require 'time'

module Anway
  class Job
    ATTRIBUTES = %w[queue reserve_for at retry backtrace created_at enqueued_at failure].freeze

    attr_accessor :jid, :type, :args, :custom, *ATTRIBUTES.map(&:to_sym)

    # Other languages read job args, so only JSON types with string hash keys
    # are valid. Topic events use the same rule.
    def self.validate_args!(args)
      raise ArgumentError, "job args must be an array: #{args.inspect}" unless args.is_a?(Array)

      validate_json!(args)
    end

    def self.validate_json!(value)
      case value
      when nil, true, false, String, Integer, Float
        nil
      when Array
        value.each { |item| validate_json!(item) }
      when Hash
        value.each do |key, item|
          raise ArgumentError, "job hash keys must be strings: #{key.inspect}" unless key.is_a?(String)

          validate_json!(item)
        end
      else
        raise ArgumentError, "job args must be JSON types: #{value.inspect}"
      end
    end

    def self.from_hash(hash)
      job = allocate

      job.jid = hash['jid']
      job.type = hash['jobtype']
      job.args = hash['args'] || []
      job.custom = hash['custom']

      ATTRIBUTES.each { |name| job.public_send("#{name}=", hash[name]) }

      job
    end

    # Options: queue, retry, reserve_for, backtrace, at, custom, jid.
    def initialize(type, args = [], **options)
      self.class.validate_json!(args)

      @jid = options[:jid] || SecureRandom.hex(12)
      @type = type
      @args = args
      @queue = options[:queue]&.to_s
      @retry = options[:retry]
      @reserve_for = options[:reserve_for]
      @backtrace = options[:backtrace]
      @custom = options[:custom]&.transform_keys(&:to_s)

      run_at(options[:at]) if options[:at]
    end

    def run_at(time)
      @at = time.to_time.utc.iso8601(9)

      self
    end

    def set_custom(key, value)
      @custom = (@custom || {}).merge(key.to_s => value)

      self
    end

    def to_h
      {
        'jid' => jid, 'jobtype' => type, 'args' => args, 'custom' => custom,
        **ATTRIBUTES.to_h { |name| [name, public_send(name)] }
      }.compact
    end
  end
end
