# frozen_string_literal: true

require_relative 'anway/version'
require_relative 'anway/errors'
require_relative 'anway/configuration'
require_relative 'anway/options'
require_relative 'anway/job'
require_relative 'anway/connection'
require_relative 'anway/pool'
require_relative 'anway/client'
require_relative 'anway/worker'
require_relative 'anway/executor'
require_relative 'anway/queues'
require_relative 'anway/runner'
require_relative 'anway/settings'
require_relative 'anway/daemon'
require_relative 'anway/server'
require_relative 'anway/console'
require_relative 'anway/web'
require_relative 'anway/puma/plugin'
require_relative 'anway/railtie' if defined?(Rails::Railtie)

module Anway
  @lock = Mutex.new

  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
    end

    def client
      @lock.synchronize do
        @client ||= Client.new(
          config.url, pool_size: config.pool_size, timeout: config.timeout, tls: config.tls
        )
      end
    end

    # Sends a job with no local class, for a worker in any language. The
    # options are the push keys of the input contract.
    def push(event, args = [], **options)
      enqueue(Job.new(event, args, **options))
    end

    # Inside a database transaction, the push waits for the commit.
    def enqueue(job)
      testing = const_defined?(:Testing) ? Testing : nil

      return testing.enqueue(job) if testing&.mode

      config.push_wrapper.call { client.push(job) }

      job.jid
    end

    # Sends the jobs with one PUSHB for each Client::MAX_BULK jobs. Returns
    # the reason for each refused job by jid, from all the sends, or {} when
    # all jobs are in. Inside a database transaction, the push waits for the
    # commit and returns nil.
    def push_bulk(jobs)
      jobs = jobs.to_a
      testing = const_defined?(:Testing) ? Testing : nil

      return testing.push_bulk(jobs) if testing&.mode

      failures = nil

      config.push_wrapper.call do
        failures = jobs.each_slice(Client::MAX_BULK).reduce({}) { |merged, slice| merged.merge(client.push_bulk(slice)) }
      end

      failures
    end

    # Sends one event to each subscription of the topic. Returns a
    # Client::Published. Inside a database transaction, the publish waits for
    # the commit and returns nil.
    def publish(topic, args = [], **options)
      Job.validate_args!(args)

      testing = const_defined?(:Testing) ? Testing : nil

      return testing.publish(topic, args, **options) if testing&.mode

      published = nil

      config.push_wrapper.call { published = client.publish(topic, args, **options) }

      published
    end

    # Sends the events with one PUBLISHB for each Client::MAX_BULK events.
    # Each event is a hash with topic: and args:, and the options of publish.
    # Returns one Client::PublishResult for each event, in the same order.
    # Inside a database transaction, the publish waits for the commit and
    # returns nil.
    def publish_bulk(events)
      events = events.to_a
      testing = const_defined?(:Testing) ? Testing : nil

      return testing.publish_bulk(events) if testing&.mode

      results = nil

      config.push_wrapper.call do
        results = events.each_slice(Client::MAX_BULK).flat_map { |slice| client.publish_bulk(slice) }
      end

      results
    end

    def reset!
      @lock.synchronize do
        @client&.close
        @client = nil
      end
    end
  end
end
