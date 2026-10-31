# frozen_string_literal: true

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
