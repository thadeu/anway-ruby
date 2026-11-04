# frozen_string_literal: true

require 'json'
require 'uri'

module Anway
  # Same operations as the anway-go client. It is safe for concurrent use.
  class Client
    DEFAULT_URL = 'tcp://127.0.0.1:7419'
    DEFAULT_PORT = 7419
    FETCH_WAIT = 2

    # The most jobs that one PUSHB takes, and the most events that one
    # PUBLISHB takes.
    MAX_BULK = 1000

    Endpoint = Data.define(:host, :port, :password, :tls)

    # The BEAT reply: the state (nil, "quiet", or "terminate"), and the thread
    # count that the server wants, or nil.
    Heartbeat = Data.define(:state, :concurrency)

    # The PUBLISH reply: the event id, the number of copies, and true when the
    # server already had an event with this id.
    Published = Data.define(:event, :jobs, :duplicate)

    # One result of a PUBLISHB: as Published, and the reason in error when the
    # server refused the event.
    PublishResult = Data.define(:event, :jobs, :duplicate, :error)

    # A blank URL uses ANWAY_URL, then the local default.
    def initialize(url = nil, pool_size: 8, timeout: 10, tls: nil, wid: nil, labels: [], identity: {})
      @endpoint = parse_url(url || ENV.fetch('ANWAY_URL', nil) || DEFAULT_URL)
      @timeout = timeout
      @wid = wid

      @pool = Pool.new(pool_size) do
        Connection.new(@endpoint, timeout: timeout, tls: tls, wid: wid, labels: labels, identity: identity)
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

    # Sends up to MAX_BULK jobs with one PUSHB. A refused job, such as a
    # duplicate jid or a unique lock, does not stop the others. Returns the
    # reason for each refused job by jid, or {} when all jobs are in. More
    # than MAX_BULK jobs raise ArgumentError before the send.
    def push_bulk(jobs)
      jobs = jobs.to_a

      raise ArgumentError, "a bulk push has at most #{MAX_BULK} jobs, not #{jobs.size}" if jobs.size > MAX_BULK

      return {} if jobs.empty?

      JSON.parse(call('PUSHB', jobs.map(&:to_h)))
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
      heartbeat(current_state).state
    end

    # Sends BEAT with the thread count of the worker, so the server can ask for
    # another count. Returns a Heartbeat.
    def heartbeat(current_state = nil, concurrency: nil)
      reply = call('BEAT', { wid: @wid, current_state: current_state, concurrency: concurrency }.compact)

      return Heartbeat.new(state: nil, concurrency: nil) if reply == 'OK'

      data = JSON.parse(reply)

      Heartbeat.new(state: data['state'], concurrency: data['concurrency'])
    end

    # Lets the client hold size connections at once, for a worker that adds
    # threads.
    def grow_pool(size)
      @pool.grow(size)
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
    def mutate(command, target, event: nil, jids: nil, regexp: nil)
      filter = { jobtype: event, jids: jids, regexp: regexp }.compact

      call('MUTATE', { cmd: command, target: target, filter: filter })

      true
    end

    # Sends one event to each subscription of the topic. With an id, a second
    # publish of the same id within unique_for seconds makes no job, and the
    # reply has duplicate true. Returns a Published.
    def publish(topic, args = [], id: nil, unique_for: nil, custom: nil)
      data = JSON.parse(call('PUBLISH', event_payload(topic, args, id: id, unique_for: unique_for, custom: custom)))

      Published.new(event: data['event'], jobs: data['jobs'], duplicate: data['duplicate'] == true)
    end

    # Sends up to MAX_BULK events with one PUBLISHB, and the server saves them
    # in one write. Each event is a hash with topic: and args:, and the
    # options of publish (id:, unique_for:, custom:). Returns one
    # PublishResult for each event, in the same order. A refused event, such
    # as a bad topic, has error, and does not stop the others. More than
    # MAX_BULK events raise ArgumentError before the send.
    def publish_bulk(events)
      events = events.to_a

      raise ArgumentError, "a bulk publish has at most #{MAX_BULK} events, not #{events.size}" if events.size > MAX_BULK

      return [] if events.empty?

      payload = events.map do |event|
        event_payload(event.fetch(:topic), event.fetch(:args, []), **event.slice(:id, :unique_for, :custom))
      end

      JSON.parse(call('PUBLISHB', payload)).map do |data|
        PublishResult.new(event: data['event'], jobs: data['jobs'], duplicate: data['duplicate'] == true, error: data['error'])
      end
    end

    # Each event of the topic makes one job in queue, with event as its job
    # type. A second call with the same topic, queue, and event sets new retry
    # and reserve_for.
    def subscribe(topic, queue:, event:, retry: nil, reserve_for: nil)
      options = { retry: binding.local_variable_get(:retry), reserve_for: reserve_for }

      call('SUBSCRIBE', { topic: topic, queue: queue, jobtype: event, **options }.compact)

      true
    end

    # A missing subscription is not an error.
    def unsubscribe(topic, queue:, event:)
      call('UNSUBSCRIBE', { topic: topic, queue: queue, jobtype: event })

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

    # The argument of PUBLISH, and of each event of PUBLISHB.
    def event_payload(topic, args, id: nil, unique_for: nil, custom: nil)
      Job.validate_args!(args)

      { topic: topic, args: args, id: id, unique_for: unique_for, custom: custom&.transform_keys(&:to_s) }.compact
    end

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
