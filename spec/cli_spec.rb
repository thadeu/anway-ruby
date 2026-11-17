# frozen_string_literal: true

require 'net/http'
require 'open3'
require 'rbconfig'
require 'timeout'

RSpec.describe 'anway command' do
  let(:root) { File.expand_path('..', __dir__) }
  let(:ruby_command) { [RbConfig.ruby, "-I#{root}/lib", "#{root}/exe/anway"] }

  def spawn_cli(url, *args, chdir: root)
    reader, writer = IO.pipe
    pid = Process.spawn({ 'ANWAY_URL' => url }, *ruby_command, *args, chdir: chdir, out: writer, err: writer)

    writer.close
    outputs << reader
    pids << pid

    [pid, reader]
  end

  def outputs
    @outputs ||= []
  end

  def pids
    @pids ||= []
  end

  def wait_exit(pid)
    Timeout.timeout(15) { Process.wait2(pid).last.exitstatus }
  end

  def read_until(reader, text)
    Timeout.timeout(15) do
      collected = +''

      collected << reader.readpartial(4096) until collected.include?(text)

      collected
    end
  end

  after do
    pids.each do |pid|
      Process.kill('KILL', pid)
      Process.wait(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
  end

  it 'prints the version' do
    output, status = Open3.capture2e(*ruby_command, '--version')

    expect(output.strip).to eq("anway #{Anway::VERSION}")
    expect(status.exitstatus).to eq(0)
  end

  it 'exits with 2 for a bad flag' do
    _output, status = Open3.capture2e(*ruby_command, '--unknown')

    expect(status.exitstatus).to eq(2)
  end

  it 'exits with 2 outside Rails without -r' do
    output, status = Open3.capture2e(*ruby_command, chdir: Dir.tmpdir)

    expect(output).to include('use -r')
    expect(status.exitstatus).to eq(2)
  end

  it 'exits with 1 when the server is down' do
    env = { 'ANWAY_URL' => 'tcp://127.0.0.1:1' }
    _output, status = Open3.capture2e(env, *ruby_command, '-r', 'spec/fixtures/jobs.rb', chdir: root)

    expect(status.exitstatus).to eq(1)
  end

  it 'derives queues from classes, runs a job, and stops at TERM' do
    server = start_server
    client = open_client(server.url)
    path = File.join(server.dir, 'result')
    pid, reader = spawn_cli(server.url, '-r', 'spec/fixtures/jobs.rb')

    startup = read_until(reader, 'anway started')

    expect(startup).to include('files')

    client.push(Anway::Job.new('FileJob', [path], queue: 'files'))

    wait_for { File.exist?(path) }

    Process.kill('TERM', pid)

    expect(wait_exit(pid)).to eq(0)
    expect(processed(client)).to eq(1)
  end

  it 'reads the YAML file, with the environment section and ERB' do
    server = start_server
    _pid, reader = spawn_cli(
      server.url, '-r', 'spec/fixtures/jobs.rb', '-C', 'spec/fixtures/anway.yml', '-e', 'test'
    )

    expect(read_until(reader, 'concurrency=3')).to include('queues=files,default')
  end

  it 'lets flags override the YAML file' do
    server = start_server
    _pid, reader = spawn_cli(
      server.url, '-r', 'spec/fixtures/jobs.rb', '-C', 'spec/fixtures/anway.yml', '-c', '7', '-q', 'only'
    )

    expect(read_until(reader, 'concurrency=7')).to include('queues=only')
  end

  it 'fetches the subscription queues and runs a published event' do
    server = start_server
    client = open_client(server.url)
    path = File.join(server.dir, 'audited')
    pid, reader = spawn_cli(server.url, '-r', 'spec/fixtures/topic_jobs.rb')

    startup = read_until(reader, 'anway started')

    expect(startup).to include('anway subscribed topic=file.saved queue=audit event=SavedFileJob')
    expect(startup).to include('queues=files,audit,default')
    expect(startup).not_to include('does not fetch')
    expect(client.publish('file.saved', [path]).jobs).to eq(1)

    wait_for { File.exist?(path) }

    Process.kill('TERM', pid)

    expect(wait_exit(pid)).to eq(0)
  end

  it 'warns about a subscription queue that a queue list leaves out' do
    server = start_server
    _pid, reader = spawn_cli(server.url, '-r', 'spec/fixtures/topic_jobs.rb', '-C', 'spec/fixtures/anway.yml')

    startup = read_until(reader, 'anway started')

    expect(startup).to include('does not fetch queue audit, so the events of topic file.saved wait there')
    expect(startup).to include('queues=files,default')
  end

  it 'sends the cron of the classes and of the YAML file with the tag, and fetches their queues' do
    web = "127.0.0.1:#{TCPServer.new('127.0.0.1', 0).then { |socket| socket.addr[1].tap { socket.close } }}"
    server = start_server('WEB_ADDR' => web, 'WEB_TOKEN' => 't')
    _pid, reader = spawn_cli(server.url, '-r', 'spec/fixtures/cron_jobs.rb', '-C', 'spec/fixtures/cron.yml')

    startup = read_until(reader, 'anway started')

    expect(startup).to include('anway scheduled tag=shop cron=2')
    expect(startup).to include('queues=reports,billing,default')

    api = Net::HTTP.new(*web.split(':').then { |host, port| [host, port.to_i] })
    cron = JSON.parse(api.get('/api/v1/schedules', 'Authorization' => 'Bearer t').body)['cron']

    expect(cron.map { |entry| entry.values_at('tag', 'jobtype', 'queue') }).to eq([%w[shop DailyReportJob reports], %w[shop credits.refill billing]])
  end

  it 'exits with 2 when the app declares cron and sets no tag' do
    server = start_server
    pid, reader = spawn_cli(server.url, '-r', 'spec/fixtures/cron_jobs.rb')

    expect(read_until(reader, 'no tag')).to include('set tag in config/anway.yml')
    expect(wait_exit(pid)).to eq(2)
  end

  it 'stops fetching at TSTP and stays alive' do
    server = start_server
    client = open_client(server.url)
    path = File.join(server.dir, 'result')
    pid, reader = spawn_cli(server.url, '-r', 'spec/fixtures/jobs.rb', '-q', 'files')

    read_until(reader, 'anway started')

    Process.kill('TSTP', pid)
    sleep 2.5

    client.push(Anway::Job.new('FileJob', [path], queue: 'files'))

    sleep 0.5

    expect(File.exist?(path)).to be(false)
    expect(Process.wait(pid, Process::WNOHANG)).to be_nil

    Process.kill('TERM', pid)

    expect(wait_exit(pid)).to eq(0)
  end
end
