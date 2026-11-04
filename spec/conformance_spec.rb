# frozen_string_literal: true

require 'fileutils'
require 'net/http'
require 'openssl'
require 'stringio'

class NoopJob
  include Anway::Worker

  def perform; end
end

class ErrorJob
  include Anway::Worker

  def perform
    raise 'failed'
  end
end

class ExceptionJob
  include Anway::Worker

  def perform
    raise NotImplementedError, 'boom'
  end
end

class OrderJob
  include Anway::Worker

  class << self
    attr_accessor :result
  end

  def perform
    self.class.result << 'job'
  end
end

class BlockingJob
  include Anway::Worker

  class << self
    attr_accessor :started, :finished
  end

  def perform
    self.class.started = true

    sleep
  end
end

class SlowJob
  include Anway::Worker

  class << self
    attr_accessor :started, :finished
  end

  def perform
    self.class.started = true

    sleep 0.3

    self.class.finished = true
  end
end

class StuckJob
  include Anway::Worker

  class << self
    attr_accessor :started, :release, :returned
  end

  def perform
    self.class.started = true

    begin
      sleep 0.01 until self.class.release
    rescue Exception # rubocop:disable Lint/RescueException
      retry
    end

    self.class.returned = true
  end
end

class PaidOrderJob
  include Anway::Worker

  anway_options topics: %w[order.paid], queue: 'billing'

  class << self
    attr_accessor :received
  end

  def perform(order)
    self.class.received << [order, job.custom['event']]
  end
end

class StoreMessageJob
  include Anway::Worker

  anway_options queue: 'store', topics: %w[chat.message]

  class << self
    attr_accessor :received
  end

  def perform(message)
    self.class.received << message
  end
end

class NotifyMessageJob
  include Anway::Worker

  anway_options queue: 'notify', topics: %w[chat.message]

  class << self
    attr_accessor :received
  end

  def perform(message)
    self.class.received << message
  end
end

class I01WelcomeJob
  include Anway::Worker

  anway_options event: 'i01.welcome'

  def perform(_user_id); end
end

class I02MergedJob
  include Anway::Worker

  anway_options event: 'i02.first', queue: 'a', retry: 1, topics: %w[i02.one i02.two], custom: { 'source' => 'app', 'tenant' => 'a' }
  anway_options event: 'i02.merged', queue: 'b', reserve_for: 60, topics: %w[i02.two i02.three], custom: { 'tenant' => 'b' }

  def perform; end
end

class I04AuditJob
  include Anway::Worker

  anway_options event: 'i04.audit', retry: 3, reserve_for: 90
  anway_options topics: %w[i04.created i04.deleted], queue: 'i04'

  class << self
    attr_accessor :received
  end

  def perform(record)
    self.class.received << [record, job.type, job.custom['topic'], job.retry, job.reserve_for]
  end
end

RSpec.describe 'client conformance' do
  let(:server) { start_server }
  let(:client) { open_client(server.url) }

  def self_signed_certificate
    key = OpenSSL::PKey::RSA.new(2048)
    certificate = OpenSSL::X509::Certificate.new
    name = OpenSSL::X509::Name.parse('/CN=localhost')

    certificate.version = 2
    certificate.serial = 1
    certificate.subject = name
    certificate.issuer = name
    certificate.public_key = key.public_key
    certificate.not_before = Time.now - 60
    certificate.not_after = Time.now + 3600

    extensions = OpenSSL::X509::ExtensionFactory.new(certificate, certificate)

    certificate.add_extension(extensions.create_extension('subjectAltName', 'DNS:localhost'))
    certificate.sign(key, OpenSSL::Digest.new('SHA256'))

    [certificate, key]
  end

  it 'C01 connects with a URL and with ANWAY_URL' do
    expect(client.info).to include('server')

    previous = ENV.fetch('ANWAY_URL', nil)
    ENV['ANWAY_URL'] = server.url

    begin
      expect(open_client(nil).info).to include('server')
    ensure
      ENV['ANWAY_URL'] = previous
    end
  end

  it 'C02 connects with a password and rejects a wrong one' do
    protected_server = start_server('SERVER_PASSWORD' => 'secret')

    expect(open_client("tcp://:secret@#{protected_server.addr}").info).to include('server')
    expect { open_client("tcp://:wrong@#{protected_server.addr}").info }.to raise_error(Anway::ServerError)
  end

  it 'C03 connects with tcp+tls' do
    certificate, key = self_signed_certificate

    Dir.mktmpdir do |dir|
      cert_file = File.join(dir, 'cert.pem')
      key_file = File.join(dir, 'key.pem')

      File.write(cert_file, certificate.to_pem)
      File.write(key_file, key.to_pem)

      secure = start_server('TLS_CERT_FILE' => cert_file, 'TLS_KEY_FILE' => key_file)
      port = secure.addr.split(':').last
      url = "tcp+tls://localhost:#{port}"

      expect(open_client(url, tls: { ca_file: cert_file }).info).to include('server')
      expect { open_client(url).info }.to raise_error(Anway::ConnectionError)
    end
  end

  it 'C04 pushes, fetches, and acks a job' do
    jid = client.push(Anway::Job.new('email', ['a@b.com', 42, { 'k' => [1.5, nil] }]))
    job = client.fetch('default')

    expect(job.jid).to eq(jid)
    expect(job.type).to eq('email')
    expect(job.args).to eq(['a@b.com', 42, { 'k' => [1.5, nil] }])
    expect(client.ack(jid)).to be(true)
  end

  it 'C05 returns nothing for an empty queue' do
    expect(client.fetch('default')).to be_nil
  end

  it 'C06 fails a job and keeps the error data' do
    jid = client.push(Anway::Job.new('x'))

    client.fetch('default')
    client.fail(jid, errtype: 'Boom', message: 'failed')

    expect(retries(client)).to eq(1)

    client.mutate('requeue', 'retries')

    failure = client.fetch('default').failure

    expect(failure).to include('errtype' => 'Boom', 'message' => 'failed')
  end

  it 'C07 raises NotUnique for a second unique push' do
    job = -> { Anway::Job.new('x', [1], unique_for: 60) }

    client.push(job.call)

    expect { client.push(job.call) }.to raise_error(Anway::NotUnique)
    expect(client.info).to include('server')
  end

  it 'C08 keeps a scheduled job out of the queue' do
    client.push(Anway::Job.new('x', at: Time.now + 3600))

    expect(client.fetch('default')).to be_nil
  end

  it 'C09 pauses and resumes a queue' do
    client.push(Anway::Job.new('x'))
    client.pause_queues('default')

    expect(client.fetch('default')).to be_nil

    client.resume_queues('default')

    expect(client.fetch('default')).not_to be_nil
  end

  it 'C10 requeues retries that match the filter' do
    %w[a b].each do |kind|
      jid = client.push(Anway::Job.new(kind))

      client.fetch('default')
      client.fail(jid, errtype: 'Boom', message: 'failed')
    end

    client.mutate('requeue', 'retries', event: 'a')

    expect(retries(client)).to eq(1)
    expect(client.fetch('default').type).to eq('a')
  end

  it 'C11 runs complete, then success' do
    bid = client.batch_new(success: Anway::Job.new('on-success'), complete: Anway::Job.new('on-complete'))

    client.push(Anway::Job.new('member', custom: { bid: bid }))
    client.batch_commit(bid)

    types = %w[member on-complete on-success].map do |expected|
      job = client.fetch('default')

      client.ack(job.jid)

      expect(job.type).to eq(expected)
    end

    expect(types.size).to eq(3)
    expect(client.batch_status(bid)).to include('total' => 1, 'pending' => 0)
  end

  it 'C12 sets and gets job progress' do
    jid = client.push(Anway::Job.new('x', track: true))

    client.track_set(jid, percent: 40, desc: 'step')

    expect(client.track_get(jid)).to include('percent' => 40, 'desc' => 'step')
  end

  it 'C13 returns queue sizes' do
    client.push(Anway::Job.new('x'))

    expect(client.queue_sizes).to eq('default' => 1)
  end

  it 'C14 works from many threads' do
    Array.new(50) { Thread.new { client.push(Anway::Job.new('x')) } }.each(&:join)

    expect(client.queue_sizes['default']).to eq(50)
  end

  it 'C15 reconnects after a server restart' do
    client.push(Anway::Job.new('x'))
    server.restart

    pushed = 3.times.any? do
      client.push(Anway::Job.new('x'))
      true
    rescue Anway::ConnectionError
      false
    end

    expect(pushed).to be(true)
    expect(client.queue_sizes['default']).to eq(2)
  end

  it 'C16 raises Closed on a closed client' do
    closed = open_client(server.url)

    closed.close

    expect { closed.push(Anway::Job.new('x')) }.to raise_error(Anway::Closed)
  end

  it 'C17 pushes jobs in bulk and returns the reason for a refused jid' do
    existing = client.push(Anway::Job.new('x', [0]))
    jobs = [Anway::Job.new('x', [1]), Anway::Job.new('x', [2], jid: existing), Anway::Job.new('x', [3])]

    failures = client.push_bulk(jobs)

    expect(failures.keys).to eq([existing])
    expect(failures[existing]).to be_a(String).and(satisfy { |reason| !reason.empty? })
    expect(client.queue_sizes['default']).to eq(3)

    fetched = Array.new(3) { client.fetch('default') }

    expect(fetched.map(&:args)).to contain_exactly([0], [1], [3])
    expect(client.push_bulk([Anway::Job.new('x', [4]), Anway::Job.new('x', [5])])).to eq({})
    expect(client.queue_sizes['default']).to eq(2)
  end

  it 'C17 raises ArgumentError for more than 1,000 jobs, before the send' do
    jobs = Array.new(Anway::Client::MAX_BULK + 1) { Anway::Job.new('x') }

    expect { client.push_bulk(jobs) }.to raise_error(ArgumentError, /at most 1000/)
    expect(client.queue_sizes).to eq({})
    expect(client.push_bulk(jobs.first(Anway::Client::MAX_BULK))).to eq({})
    expect(client.queue_sizes['default']).to eq(Anway::Client::MAX_BULK)
  end

  it 'T01 publishes one copy to each subscription' do
    client.subscribe('chat.message', queue: 'realtime', event: 'chat.broadcast')
    client.subscribe('chat.message', queue: 'cassandra', event: 'chat.store', retry: 3)
    client.subscribe('chat.message', queue: 'push', event: 'chat.notify', reserve_for: 60)

    published = client.publish('chat.message', [{ 'room' => 'general', 'body' => 'hi' }], id: 'msg-42', custom: { 'source' => 'web' })

    expect(published).to eq(Anway::Client::Published.new(event: 'msg-42', jobs: 3, duplicate: false))

    copies = { 'realtime' => 'chat.broadcast', 'cassandra' => 'chat.store', 'push' => 'chat.notify' }.map do |queue, event|
      job = client.fetch(queue)

      expect(job.type).to eq(event)
      expect(job.args).to eq([{ 'room' => 'general', 'body' => 'hi' }])
      expect(job.custom).to eq('topic' => 'chat.message', 'event' => 'msg-42', 'source' => 'web')

      job
    end

    expect(copies.map(&:jid).uniq.size).to eq(3)
    expect(copies[1].retry).to eq(3)
    expect(copies[2].reserve_for).to eq(60)
  end

  it 'T02 keeps one subscription for the same topic, queue, and job type' do
    2.times { expect(client.subscribe('order.paid', queue: 'billing', event: 'invoice')).to be(true) }

    expect(client.publish('order.paid', [1]).jobs).to eq(1)
    expect(client.unsubscribe('order.paid', queue: 'billing', event: 'invoice')).to be(true)
    expect(client.unsubscribe('order.paid', queue: 'billing', event: 'invoice')).to be(true)
    expect(client.publish('order.paid', [2]).jobs).to eq(0)
    expect(client.queue_sizes['billing']).to eq(1)
  end

  it 'T03 makes no job for a second publish with the same event id' do
    client.subscribe('order.paid', queue: 'billing', event: 'invoice')

    first = client.publish('order.paid', [1], id: 'order-1')
    second = client.publish('order.paid', [1], id: 'order-1')

    expect(first).to have_attributes(event: 'order-1', jobs: 1, duplicate: false)
    expect(second).to have_attributes(event: 'order-1', jobs: 0, duplicate: true)
    expect(client.queue_sizes['billing']).to eq(1)

    unchecked = client.publish('order.paid', [1], id: 'order-1', unique_for: 0)

    expect(unchecked).to have_attributes(jobs: 1, duplicate: false)
  end

  it 'T04 sends an event with no subscription to the dead set' do
    published = client.publish('audit.log', [{ 'user' => 7 }])

    expect(published.event).to start_with('evt-')
    expect(published).to have_attributes(jobs: 0, duplicate: false)
    expect(client.info.dig('faktory', 'tasks', 'Dead', 'size')).to eq(1)

    client.subscribe('audit.log', queue: 'audit', event: 'audit.write')
    client.mutate('requeue', 'dead', event: 'audit.log')

    copy = client.fetch('audit')

    expect(copy.type).to eq('audit.write')
    expect(copy.args).to eq([{ 'user' => 7 }])
    expect(copy.custom).to include('topic' => 'audit.log', 'event' => published.event)
  end

  it 'T04 rejects args that are not JSON types before it sends' do
    expect { client.publish('audit.log', [{ user: 7 }]) }.to raise_error(ArgumentError)
    expect { client.publish('audit.log', 'text') }.to raise_error(ArgumentError)
    expect(client.info.dig('faktory', 'tasks', 'Dead', 'size')).to eq(0)
  end
end

RSpec.describe 'input contract conformance' do
  let(:server) { start_server }
  let(:client) { open_client(server.url) }

  it 'I01 sends the contract keys in custom, and the event as jobtype' do
    options = {
      queue: 'low', unique_for: 60, unique_until: :start, expires_in: 300, expires_at: Time.utc(2099, 1, 2, 3, 4, 5),
      track: true, on_dead: { event: 'mail.bounced', queue: 'dead_letters' },
      custom: { 'unique_for' => 1, :tenant => 'acme' }
    }

    custom = {
      'tenant' => 'acme', 'unique_for' => 60, 'unique_until' => 'start', 'expires_in' => 300,
      'expires_at' => '2099-01-02T03:04:05.000000000Z', 'track' => 1,
      'on_dead' => { 'jobtype' => 'mail.bounced', 'queue' => 'dead_letters' }
    }

    Anway::Testing.fake!

    I01WelcomeJob.set(**options).perform_async(1)
    Anway.push('i01.welcome', [1], **options)

    wire = Anway::Testing.jobs.map { |job| job.to_h.except('jid', 'backtrace') }

    expect(wire).to eq([{ 'jobtype' => 'i01.welcome', 'queue' => 'low', 'args' => [1], 'custom' => custom }] * 2)

    jid = client.push(Anway::Job.new('i01.welcome', [1], **options))
    fetched = client.fetch('low')

    expect(fetched).to have_attributes(jid: jid, type: 'i01.welcome')
    expect(fetched.custom).to include(custom.except('expires_in', 'expires_at'))
  end

  it 'I02 merges two option sets in order' do
    expect(I02MergedJob.anway_options).to eq(
      event: 'i02.merged', queue: 'b', retry: 1, reserve_for: 60,
      topics: %w[i02.one i02.two i02.three], custom: { 'source' => 'app', 'tenant' => 'b' }
    )

    expect(I02MergedJob.subscriptions.map(&:topic)).to eq(%w[i02.one i02.two i02.three])
    expect(I02MergedJob.subscriptions.map { |item| [item.queue, item.event, item.retry, item.reserve_for] }.uniq).to eq(
      [['b', 'i02.merged', 1, 60]]
    )

    expect(Anway::Worker.find('i02.merged')).to eq(I02MergedJob)
    expect { Anway::Worker.find('i02.first') }.to raise_error(Anway::UnknownJob)

    Anway::Testing.fake!

    I02MergedJob.set(queue: 'c', custom: { 'trace' => 't1' }).perform_async

    expect(Anway::Testing.jobs.last.to_h).to include(
      'jobtype' => 'i02.merged', 'queue' => 'c', 'retry' => 1, 'reserve_for' => 60,
      'custom' => { 'source' => 'app', 'tenant' => 'b', 'trace' => 't1' }
    )

    expect(Anway::Options.merge({ topics: %w[a b] }, { topics: %w[b c], queue: 'x' }, { queue: 'y' })).to eq(
      topics: %w[a b c], queue: 'y'
    )
  end

  it 'I03 raises for a second class with the same event' do
    first = stub_const('I03FirstJob', Class.new)
    second = stub_const('I03SecondJob', Class.new)

    first.include(Anway::Worker)
    first.anway_options(event: 'i03.same')
    second.include(Anway::Worker)

    expect { second.anway_options(event: 'i03.same') }.to raise_error(ArgumentError, /i03\.same.*I03FirstJob/)
    expect(second.anway_options[:event]).to eq('I03SecondJob')
    expect { stub_const('I03ThirdJob', Class.new(first)).anway_options(event: 'i03.same') }.to raise_error(ArgumentError)
    expect(Anway::Worker.find('i03.same')).to eq(first)

    reloaded = stub_const('I03FirstJob', Class.new)

    reloaded.include(Anway::Worker)
    reloaded.anway_options(event: 'i03.same')

    expect(Anway::Worker.find('i03.same')).to eq(reloaded)
  end

  it 'I04 sends one SUBSCRIBE for each topic of a declaration, and runs the copies' do
    I04AuditJob.received = []

    log = StringIO.new

    run_in_thread(Anway::Runner.new(url: server.url, concurrency: 1, queues: ['i04'], logger: Logger.new(log)))

    wait_for { log.string.include?('anway started') }

    %w[i04.created i04.deleted].each do |topic|
      expect(log.string.scan("anway subscribed topic=#{topic} queue=i04 event=i04.audit").size).to eq(1)
    end

    created = client.publish('i04.created', [{ 'id' => 1 }])
    deleted = client.publish('i04.deleted', [{ 'id' => 2 }])

    expect([created.jobs, deleted.jobs]).to eq([1, 1])

    wait_for { I04AuditJob.received.size == 2 }

    expect(I04AuditJob.received).to contain_exactly(
      [{ 'id' => 1 }, 'i04.audit', 'i04.created', 3, 90],
      [{ 'id' => 2 }, 'i04.audit', 'i04.deleted', 3, 90]
    )
  end
end

RSpec.describe 'worker conformance' do
  let(:server) { start_server }
  let(:client) { open_client(server.url) }

  def runner(**options)
    Anway::Runner.new(url: server.url, concurrency: 1, **options)
  end

  it 'W01 runs a job and acks it' do
    run_in_thread(runner)
    client.push(Anway::Job.new('NoopJob'))

    wait_for { processed(client) == 1 }
  end

  it 'W02, W03, and W04 fail the job and continue' do
    run_in_thread(runner)

    %w[ErrorJob ExceptionJob UnknownJobType NoopJob].each { |type| client.push(Anway::Job.new(type)) }

    wait_for { retries(client) == 3 && processed(client) == 1 }
  end

  it 'W05 wraps a job in middleware order' do
    OrderJob.result = []

    wrap = Struct.new(:name) do
      def call(_job)
        OrderJob.result << name

        yield
      end
    end

    Anway.config.use(wrap.new('a'))
    Anway.config.use(wrap.new('b'))

    run_in_thread(runner)
    client.push(Anway::Job.new('OrderJob'))

    wait_for { processed(client) == 1 }

    expect(OrderJob.result).to eq(%w[a b job])
  end

  it 'W06 fails unfinished jobs at server terminate' do
    BlockingJob.started = false

    script = TerminatingServer.new(jid: 'blocked', event: 'BlockingJob')
    current = Anway::Runner.new(url: script.url, concurrency: 1, beat_interval: 0.02, timeout: 0.05, cancel_grace: 0.1)
    thread = run_in_thread(current)

    wait_for { BlockingJob.started }

    expect(thread.join(5)).not_to be_nil
    expect(script.failures).to contain_exactly(include('jid' => 'blocked', 'errtype' => 'Anway::Shutdown'))
  ensure
    script&.close
  end

  it 'W07 lets running jobs finish at a local stop' do
    SlowJob.started = false
    SlowJob.finished = false

    current = runner
    thread = run_in_thread(current)

    client.push(Anway::Job.new('SlowJob'))

    wait_for { SlowJob.started }

    current.stop

    expect(thread.join(5)).not_to be_nil
    expect(SlowJob.finished).to be(true)
    expect(processed(client)).to eq(1)
  end

  it 'W11 keeps running across a server restart' do
    current = runner(beat_interval: 0.05)
    thread = run_in_thread(current)

    client.push(Anway::Job.new('NoopJob'))

    wait_for { processed(client) == 1 }

    server.stop
    server.start

    fresh = open_client(server.url)

    fresh.push(Anway::Job.new('NoopJob'))

    wait_for(10) { processed(fresh) == 2 }

    expect(thread).to be_alive
  end

  it 'W12 starts and stops threads when a beat asks, and a stopping thread finishes its job' do
    web = "127.0.0.1:#{TCPServer.new('127.0.0.1', 0).then { |socket| socket.addr[1].tap { socket.close } }}"
    scaled = start_server('WEB_ADDR' => web, 'WEB_TOKEN' => 't')
    current = Anway::Runner.new(url: scaled.url, concurrency: 1, beat_interval: 0.05)
    api = Net::HTTP.new(*web.split(':').then { |host, port| [host, port.to_i] })

    view = lambda do
      body = api.get('/api/v1/workers', 'Authorization' => 'Bearer t').body

      JSON.parse(body)['workers'].find { |worker| worker['wid'] == current.wid }
    end

    scale = lambda do |count|
      api.patch("/api/v1/workers/#{current.wid}", JSON.generate(concurrency: count), 'Authorization' => 'Bearer t')
    end

    alive = -> { current.instance_variable_get(:@processors).count(&:alive?) }

    run_in_thread(current)

    wait_for { view.call&.fetch('scalable') }

    scale.call(3)

    wait_for { view.call['concurrency'] == 3 && view.call['wanted'].nil? }

    expect(alive.call).to eq(3)

    SlowJob.started = SlowJob.finished = false
    jobs = open_client(scaled.url)

    jobs.push(Anway::Job.new('SlowJob'))

    wait_for { SlowJob.started }

    scale.call(1)

    wait_for(10) { view.call['concurrency'] == 1 && alive.call == 1 }

    expect(SlowJob.finished).to be(true)
    expect(processed(jobs)).to eq(1)
  end

  it 'W12 reports a new thread count at once, not at the next beat' do
    web = "127.0.0.1:#{TCPServer.new('127.0.0.1', 0).then { |socket| socket.addr[1].tap { socket.close } }}"
    scaled = start_server('WEB_ADDR' => web, 'WEB_TOKEN' => 't')
    current = Anway::Runner.new(url: scaled.url, concurrency: 1, beat_interval: 2)
    api = Net::HTTP.new(*web.split(':').then { |host, port| [host, port.to_i] })

    view = lambda do
      body = api.get('/api/v1/workers', 'Authorization' => 'Bearer t').body

      JSON.parse(body)['workers'].find { |worker| worker['wid'] == current.wid }
    end

    run_in_thread(current)

    wait_for { view.call&.fetch('scalable') }

    api.patch("/api/v1/workers/#{current.wid}", JSON.generate(concurrency: 3), 'Authorization' => 'Bearer t')

    wait_for(5) { current.instance_variable_get(:@processors).count(&:alive?) == 3 }
    wait_for(0.5) { view.call['concurrency'] == 3 }
  end

  it 'T05 sends its subscriptions at start and runs the copies of an event' do
    PaidOrderJob.received = []

    log = StringIO.new
    current = runner(queues: ['billing'], logger: Logger.new(log))

    run_in_thread(current)

    wait_for { log.string.include?('anway started') }

    expect(log.string).to include('anway subscribed topic=order.paid queue=billing event=PaidOrderJob')

    first = client.publish('order.paid', [{ 'id' => 1 }])
    second = client.publish('order.paid', [{ 'id' => 2 }], id: 'order-2')

    expect([first.jobs, second.jobs]).to eq([1, 1])

    wait_for { PaidOrderJob.received.size == 2 }

    expect(PaidOrderJob.received).to contain_exactly([{ 'id' => 1 }, first.event], [{ 'id' => 2 }, 'order-2'])
  end

  it 'T06 runs one copy of each event in each of two workers' do
    StoreMessageJob.received = []
    NotifyMessageJob.received = []

    logs = [StringIO.new, StringIO.new]

    run_in_thread(runner(queues: ['store'], subscriptions: StoreMessageJob.subscriptions, logger: Logger.new(logs[0])))
    run_in_thread(runner(queues: ['notify'], subscriptions: NotifyMessageJob.subscriptions, logger: Logger.new(logs[1])))

    wait_for { logs.all? { |log| log.string.include?('anway started') } }

    messages = Array.new(3) { |index| { 'body' => "m#{index}" } }

    messages.each { |message| expect(client.publish('chat.message', [message]).jobs).to eq(2) }

    wait_for { processed(client) == 6 }

    expect(StoreMessageJob.received).to match_array(messages)
    expect(NotifyMessageJob.received).to match_array(messages)
  end

  it 'W08 stays alive after quiet and stops fetching' do
    script = ScriptedServer.new(last_quiet_beat: 20)
    current = Anway::Runner.new(url: script.url, concurrency: 1, beat_interval: 0.05)
    thread = run_in_thread(current)

    expect(thread.join(10)).not_to be_nil
    expect(script.beats).to be > 20
    expect(script.quiet_fetches).to be <= 2
  ensure
    script&.close
  end

  it 'W09 cancels running jobs after the timeout' do
    BlockingJob.started = false

    current = runner(timeout: 0.05)
    thread = run_in_thread(current)

    client.push(Anway::Job.new('BlockingJob'))

    wait_for { BlockingJob.started }

    current.stop

    expect(thread.join(5)).not_to be_nil
    expect(retries(client)).to eq(1)
  end

  it 'W10 does not let a job block the shutdown' do
    StuckJob.started = false
    StuckJob.release = false
    StuckJob.returned = false

    current = runner(timeout: 0.05, cancel_grace: 0.05)
    thread = run_in_thread(current)

    client.push(Anway::Job.new('StuckJob'))

    wait_for { StuckJob.started }

    current.stop

    expect(thread.join(5)).not_to be_nil

    StuckJob.release = true
    sleep 0.1

    expect(retries(client)).to eq(1)
    expect(processed(client)).to eq(0)
  end
end

# Replies quiet to beats 2 to the last quiet beat, and then terminate.
class ScriptedServer
  attr_reader :beats, :quiet_fetches

  def initialize(last_quiet_beat:)
    @last_quiet_beat = last_quiet_beat
    @beats = 0
    @quiet_fetches = 0
    @lock = Mutex.new
    @listener = TCPServer.new('127.0.0.1', 0)

    @acceptor = Thread.new do
      loop { start_connection(@listener.accept) }
    rescue IOError
      nil
    end
  end

  def url
    "tcp://127.0.0.1:#{@listener.addr[1]}"
  end

  def close
    @listener.close
    @acceptor.kill
  end

  private

  def start_connection(socket)
    Thread.new do
      socket.write("+HI {\"v\":2}\r\n")

      while (line = socket.gets)
        socket.write(reply(line.split(' ', 2).first))
      end
    rescue SystemCallError, IOError
      nil
    end
  end

  def reply(verb)
    case verb
    when 'FETCH'
      @lock.synchronize { @quiet_fetches += 1 if @beats > 1 }
      sleep 0.005

      "$-1\r\n"
    when 'BEAT'
      beat_reply(@lock.synchronize { @beats += 1 })
    else
      "+OK\r\n"
    end
  end

  def beat_reply(count)
    return "+OK\r\n" if count == 1

    body = %({"state":"#{count > @last_quiet_beat ? 'terminate' : 'quiet'}"})

    "$#{body.bytesize}\r\n#{body}\r\n"
  end
end

# TerminatingServer gives out one job, and answers terminate to each beat
# after that. It records the FAIL commands that it receives.
class TerminatingServer
  attr_reader :failures

  def initialize(jid:, event:)
    @job = JSON.generate('jid' => jid, 'jobtype' => event, 'args' => [], 'queue' => 'default')
    @given = false
    @failures = []
    @lock = Mutex.new
    @listener = TCPServer.new('127.0.0.1', 0)

    @acceptor = Thread.new do
      loop { start_connection(@listener.accept) }
    rescue IOError
      nil
    end
  end

  def url
    "tcp://127.0.0.1:#{@listener.addr[1]}"
  end

  def close
    @listener.close
    @acceptor.kill
  end

  private

  def start_connection(socket)
    Thread.new do
      socket.write("+HI {\"v\":2}\r\n")

      while (line = socket.gets)
        verb, payload = line.chomp.split(' ', 2)

        socket.write(reply(verb, payload))
      end
    rescue SystemCallError, IOError
      nil
    end
  end

  def reply(verb, payload)
    case verb
    when 'FETCH' then fetch_reply
    when 'BEAT' then @lock.synchronize { @given } ? bulk('{"state":"terminate"}') : "+OK\r\n"
    when 'FAIL'
      @lock.synchronize { @failures << JSON.parse(payload) }

      "+OK\r\n"
    else
      "+OK\r\n"
    end
  end

  def fetch_reply
    first = @lock.synchronize { !@given && (@given = true) }

    sleep 0.005 unless first

    first ? bulk(@job) : "$-1\r\n"
  end

  def bulk(body)
    "$#{body.bytesize}\r\n#{body}\r\n"
  end
end
