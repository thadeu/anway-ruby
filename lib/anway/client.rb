# frozen_string_literal: true

require 'json'
require 'uri'

module Anway
  # Same operations as the anway-go client. It is safe for concurrent use.
  class Client
    DEFAULT_URL = 'tcp://127.0.0.1:7419'
    DEFAULT_PORT = 7419
    FETCH_WAIT = 2

    Endpoint = Data.define(:host, :port, :password, :tls)

    # A blank URL uses SERVER_URL, then the local default.
    def initialize(url = nil, pool_size: 8, timeout: 10, tls: nil, wid: nil, labels: [])
      @endpoint = parse_url(url || ENV.fetch('SERVER_URL', nil) || DEFAULT_URL)
      @timeout = timeout
      @wid = wid

      @pool = Pool.new(pool_size) do
        Connection.new(@endpoint, timeout: timeout, tls: tls, wid: wid, labels: labels)
      end
    end

    def close
      @pool.close
    end

    # Raises NotUnique when a unique lock blocks the job.
    def push(job)
      call('PUSH', job.to_h)

      job.jid
    end

    # Returns the next job, or nil when no job arrives in about 2 seconds.
    def fetch(*queues)
      reply = call('FETCH', queues.join(' '), wait: FETCH_WAIT)

      reply && Job.from_hash(JSON.parse(reply))
    end

    def ack(jid)
      call('ACK', { jid: jid })

      true
    end

    def fail(jid, errtype:, message:, backtrace: [])
      call('FAIL', { jid: jid, errtype: errtype, message: message, backtrace: backtrace })

      true
    end

    # Returns nil, "quiet", or "terminate".
    def beat(current_state = nil)
      reply = call('BEAT', { wid: @wid, current_state: current_state }.compact)

      reply == 'OK' ? nil : JSON.parse(reply)['state']
    end

    def info
      JSON.parse(call('INFO'))
    end

    def queue_sizes
      info.dig('faktory', 'queues') || {}
    end

    def pause_queues(*queues)
      queue_command('PAUSE', queues)
    end

    def resume_queues(*queues)
      queue_command('RESUME', queues)
    end

    def remove_queues(*queues)
      queue_command('REMOVE', queues)
    end

    # The command is "kill", "discard", "requeue", or "clear".
    # The target is "retries", "scheduled", or "dead".
    def mutate(command, target, jobtype: nil, jids: nil, regexp: nil)
      filter = { jobtype: jobtype, jids: jids, regexp: regexp }.compact

      call('MUTATE', { cmd: command, target: target, filter: filter })

      true
    end

    def batch_new(success: nil, complete: nil, parent_bid: nil, description: nil)
      definition = {
        success: success&.to_h, complete: complete&.to_h, parent_bid: parent_bid, description: description
      }.compact

      call('BATCH', "NEW #{JSON.generate(definition)}")
    end

    def batch_open(bid)
      call('BATCH', "OPEN #{bid}")

      true
    end

    def batch_commit(bid)
      call('BATCH', "COMMIT #{bid}")

      true
    end

    def batch_status(bid)
      JSON.parse(call('BATCH', "STATUS #{bid}"))
    end

    def track_get(jid)
      JSON.parse(call('TRACK', "GET #{jid}"))
    end

    def track_set(jid, percent: nil, desc: nil, reserve_until: nil)
      update = { jid: jid, percent: percent, desc: desc, reserve_until: reserve_until&.to_time&.utc&.iso8601(9) }

      call('TRACK', "SET #{JSON.generate(update.compact)}")

      true
    end

    private

    def queue_command(action, queues)
      call('QUEUE', "#{action} #{queues.join(' ')}")

      true
    end

    def call(verb, argument = nil, wait: 0)
      @pool.with(timeout: @timeout) { |connection| connection.command(verb, argument, wait: wait) }
    end

    def parse_url(url)
      uri = URI.parse(url)

      raise ArgumentError, "unsupported scheme: #{uri.scheme}" unless %w[tcp tcp+tls].include?(uri.scheme)

      password = uri.password && URI.decode_www_form_component(uri.password)

      Endpoint.new(host: uri.hostname, port: uri.port || DEFAULT_PORT, password: password, tls: uri.scheme == 'tcp+tls')
    end
  end
end
