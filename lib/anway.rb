# frozen_string_literal: true

require_relative 'anway/version'
require_relative 'anway/errors'
require_relative 'anway/configuration'
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

    # Sends a job with no local class, for a worker in any language.
    def push(type, args = [], **options)
      enqueue(Job.new(type, args, **options))
    end

    # Inside a database transaction, the push waits for the commit.
    def enqueue(job)
      testing = const_defined?(:Testing) ? Testing : nil

      return testing.enqueue(job) if testing&.mode

      config.push_wrapper.call { client.push(job) }

      job.jid
    end

    def reset!
      @lock.synchronize do
        @client&.close
        @client = nil
      end
    end
  end
end
