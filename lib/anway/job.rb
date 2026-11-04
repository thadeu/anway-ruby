# frozen_string_literal: true

require 'json'
require 'securerandom'
require 'time'
require_relative 'options'

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

    # The event goes on the wire as jobtype. The options are the push keys of
    # the input contract (Anway::Options::PUSH). An unknown key raises
    # ArgumentError. jid is optional, and the default is a new random id.
    def initialize(event, args = [], jid: nil, **options)
      self.class.validate_json!(args)

      Options.check!(options, Options::PUSH)

      fields = Options.wire(options)

      @jid = jid || SecureRandom.hex(12)
      @type = event
      @args = args

      @queue = fields['queue']
      @retry = fields['retry']
      @reserve_for = fields['reserve_for']
      @backtrace = fields['backtrace']
      @at = fields['at']
      @custom = fields['custom']
    end

    def run_at(time)
      @at = Options.time(time)

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
