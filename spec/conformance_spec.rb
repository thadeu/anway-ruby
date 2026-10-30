# frozen_string_literal: true

require 'fileutils'
require 'openssl'

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

  it 'C01 connects with a URL and with SERVER_URL' do
    expect(client.info).to include('server')

    previous = ENV.fetch('SERVER_URL', nil)
    ENV['SERVER_URL'] = server.url

    begin
      expect(open_client(nil).info).to include('server')
    ensure
      ENV['SERVER_URL'] = previous
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
    job = -> { Anway::Job.new('x', [1], custom: { unique_for: 60 }) }

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

    client.mutate('requeue', 'retries', jobtype: 'a')

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
    jid = client.push(Anway::Job.new('x', custom: { track: 1 }))

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

    current = runner(beat_interval: 0.02, timeout: 0.05, cancel_grace: 0.1)
    thread = run_in_thread(current)

    client.push(Anway::Job.new('BlockingJob'))

    wait_for { BlockingJob.started }

    server.signal('INT')

    expect(thread.join(5)).not_to be_nil

    server.restart

    fresh = open_client(server.url)

    expect(retries(fresh)).to eq(1)

    fresh.mutate('requeue', 'retries')

    expect(fresh.fetch('default').failure).to include('errtype' => 'Anway::Shutdown')
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
