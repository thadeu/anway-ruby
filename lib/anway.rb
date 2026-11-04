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

    def reset!
      @lock.synchronize do
        @client&.close
        @client = nil
      end
    end
  end
end
