# frozen_string_literal: true

require 'fileutils'
require 'rbconfig'
require 'socket'
require 'stringio'
require 'timeout'
require 'tmpdir'

# The embedded server, the anway command modes, and the Puma plugin, with the
# real server binary and real processes.
RSpec.describe 'embedded server' do
  let(:root) { File.expand_path('..', __dir__) }
  let(:dir) { Dir.mktmpdir }
  let(:port) { free_port }
  let(:bind) { "127.0.0.1:#{port}" }
  let(:config) { File.join(dir, 'anway.yml') }

  before do
    skip 'SERVER_BIN is not set' unless ENV['SERVER_BIN']

    File.write(config, <<~YAML)
      require: #{root}/spec/fixtures/jobs.rb
      queues: [files]
      server:
        bind: #{bind}
        data: #{dir}/data
    YAML
  end

  after do
    pids.each do |pid|
      Process.kill('KILL', pid)
      Process.wait(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end

    FileUtils.rm_rf(dir)
  end

  def pids
    @pids ||= []
  end

  def free_port
    server = TCPServer.new('127.0.0.1', 0)

    server.addr[1]
  ensure
    server.close
  end

  def open?(target = port)
    Socket.tcp('127.0.0.1', target, connect_timeout: 0.2).close

    true
  rescue SystemCallError
    false
  end

  def base_env
    { 'ANWAY_SERVER_PATH' => ENV.fetch('SERVER_BIN'), 'ANWAY_URL' => nil, 'RAILS_ENV' => nil, 'APP_ENV' => 'development' }
  end

  def spawn_process(env, *command)
    reader, writer = IO.pipe
    pid = Process.spawn(base_env.merge(env), *command, chdir: dir, out: writer, err: writer)

    writer.close
    pids << pid

    [pid, reader]
  end

  def anway(*args, env: {})
    spawn_process(env, RbConfig.ruby, "-I#{root}/lib", "#{root}/exe/anway", *args, '-C', config)
  end

  def read_until(reader, text)
    Timeout.timeout(20) do
      collected = +''

      collected << reader.readpartial(4096) until collected.include?(text)

      collected
    end
  end

  def exit_status(pid, limit = 20)
    Timeout.timeout(limit) { Process.wait2(pid).last }
  end

  describe Anway::Server do
    let(:settings) { Anway::Settings.load(path: config, env: {}) }

    around do |example|
      previous = ENV.fetch('ANWAY_SERVER_PATH', nil)

      ENV['ANWAY_SERVER_PATH'] = ENV.fetch('SERVER_BIN', nil)
      example.run
    ensure
      ENV['ANWAY_SERVER_PATH'] = previous
    end

    after { embedded.each(&:stop) }

    def embedded
      @embedded ||= []
    end

    def new_server
      described_class.new(settings).tap { |server| embedded << server }
    end

    it 'starts the binary, waits for its port, and stops it' do
      server = new_server

      expect(server.start).to be(true)
      expect(open?).to be(true)
      expect(File.directory?("#{dir}/data")).to be(true)

      client = open_client(settings.client_url)

      expect(client.info).to include('faktory')

      client.close
      server.stop

      expect(open?).to be(false)
    end

    it 'uses a server that already listens on the address' do
      other = new_server

      other.start

      server = new_server

      expect(server.start).to be(false)
      expect(server.pid).to be_nil
    end

    it 'does not use a server from an earlier start when the web token is random' do
      new_server.start

      content = { 'server' => { 'bind' => bind, 'data' => "#{dir}/data", 'web' => "127.0.0.1:#{free_port}" } }
      random = Anway::Settings.new(content, environment: 'development', env: {})

      expect { described_class.new(random).start }.to raise_error(Anway::Error, /another web token.*server.web_token/)
    end

    it 'explains how to go on when no binary exists for the platform' do
      stub_const('Anway::Server::BUNDLED', File.join(dir, 'missing'))

      expect { described_class.executable({}) }.to raise_error(Anway::Error, /ANWAY_SERVER_PATH.*url/)
    end
  end

  describe 'anway command' do
    it 'runs only the server with `anway server`, and stops at TERM' do
      pid, reader = anway('server')

      read_until(reader, 'server started')

      expect(open?).to be(true)

      Process.kill('TERM', pid)

      expect(exit_status(pid).exitstatus).to eq(0)
      expect(open?).to be(false)
    end

    it 'runs the embedded server and the workers without a url, and stops both' do
      pid, reader = anway

      read_until(reader, 'anway started')

      client = open_client("tcp://#{bind}")
      path = File.join(dir, 'result')

      client.push(Anway::Job.new('FileJob', [path], queue: 'files'))

      Timeout.timeout(10) { sleep 0.05 until File.exist?(path) }

      Process.kill('TERM', pid)

      expect(exit_status(pid).exitstatus).to eq(0)
      expect(open?).to be(false)
    end

    it 'tells the app that it runs in a worker process' do
      mark = File.join(dir, 'mark')
      pid, reader = anway('worker', '-r', "#{root}/spec/fixtures/worker_mark.rb", env: { 'WORKER_MARK' => mark, 'ANWAY_URL' => start_server.url })

      read_until(reader, 'anway started')

      expect(File.read(mark)).to eq('1')

      Process.kill('TERM', pid)

      expect(exit_status(pid).exitstatus).to eq(0)
    end

    it 'runs the console with the server, and serves it through Anway::Web under a path' do
      skip 'CONSOLE_BIN is not set' unless ENV['CONSOLE_BIN']

      console_port = free_port

      File.write(config, <<~YAML)
        require: #{root}/spec/fixtures/jobs.rb
        queues: [files]
        server:
          bind: #{bind}
          data: #{dir}/data
          web: 127.0.0.1:#{free_port}
        console:
          path: #{ENV.fetch('CONSOLE_BIN')}
          bind: 127.0.0.1:#{console_port}
      YAML

      pid, reader = anway

      read_until(reader, 'anway started')

      web = Anway::Web.new("http://127.0.0.1:#{console_port}")
      env = { 'REQUEST_METHOD' => 'GET', 'SCRIPT_NAME' => '/anway', 'PATH_INFO' => '/', 'QUERY_STRING' => '', 'HTTP_HOST' => 'shop.test', 'rack.url_scheme' => 'http', 'rack.input' => StringIO.new }
      status, _, body = web.call(env)

      expect(status).to eq(200)
      expect(body.join).to include('<base href="/anway/"/>').and include('Overview')

      Process.kill('TERM', pid)

      expect(exit_status(pid).exitstatus).to eq(0)
      expect(open?(console_port)).to be(false)
    end

    it 'runs no server with `anway worker`' do
      pid, = anway('worker')

      expect(exit_status(pid).exitstatus).to eq(1)
      expect(open?).to be(false)
    end

    it 'runs no server when ANWAY_URL is set' do
      server = start_server
      pid, reader = anway(env: { 'ANWAY_URL' => server.url })

      read_until(reader, 'anway started')

      expect(open?).to be(false)

      Process.kill('TERM', pid)

      expect(exit_status(pid).exitstatus).to eq(0)
    end
  end

  describe 'Puma plugin' do
    let(:web_port) { free_port }

    before do
      FileUtils.mkdir_p(File.join(dir, 'config'))
      FileUtils.mv(config, File.join(dir, 'config/anway.yml'))

      File.write(File.join(dir, 'config.ru'), "run ->(_env) { [200, {}, ['ok']] }\n")
      File.write(File.join(dir, 'config/puma.rb'), "bind 'tcp://127.0.0.1:#{web_port}'\nplugin :anway\n")
    end

    def puma(env)
      spawn_process(env, RbConfig.ruby, '-rbundler/setup', Gem.bin_path('puma', 'puma'), '-C', 'config/puma.rb')
    end

    it 'starts the server and the workers with Puma, and stops them with Puma' do
      pid, reader = puma('ANWAY_IN_PUMA' => 'true')

      read_until(reader, 'anway started with pid')
      Timeout.timeout(20) { sleep 0.05 until open? }

      client = open_client("tcp://#{bind}")
      path = File.join(dir, 'result')

      client.push(Anway::Job.new('FileJob', [path], queue: 'files'))

      Timeout.timeout(15) { sleep 0.05 until File.exist?(path) }

      Process.kill('INT', pid)

      expect(exit_status(pid, 60)).to be_success
      expect(open?).to be(false)
    end

    it 'starts nothing when ANWAY_IN_PUMA is false' do
      pid, reader = puma('ANWAY_IN_PUMA' => 'false')

      read_until(reader, 'Use Ctrl-C to stop')
      sleep 1

      expect(open?).to be(false)
      expect(open?(web_port)).to be(true)

      Process.kill('INT', pid)

      expect(exit_status(pid)).to be_success
    end
  end
end
