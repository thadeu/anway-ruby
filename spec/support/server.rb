# frozen_string_literal: true

require 'socket'
require 'tmpdir'

class TestServer
  attr_reader :addr, :dir, :pid

  def initialize(env = {})
    @env = env
    @dir = Dir.mktmpdir
    @addr = "127.0.0.1:#{free_port}"

    start
  end

  def url
    "tcp://#{addr}"
  end

  def start
    env = { 'BIND_ADDR' => addr, 'DATA_DIR' => dir, 'SHUTDOWN_TIMEOUT' => '1s' }.merge(@env)

    @pid = Process.spawn(env, ENV.fetch('SERVER_BIN'), out: File::NULL, err: File::NULL)

    wait_for_port
  end

  def signal(name)
    Process.kill(name, pid)
  end

  def kill
    return unless pid

    Process.kill('KILL', pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  ensure
    @pid = nil
  end

  def restart
    kill
    start
  end

  # stop asks the server to shut down, as a deploy or a Puma restart does.
  def stop
    return unless pid

    Process.kill('INT', pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  ensure
    @pid = nil
  end

  def cleanup
    kill
    FileUtils.rm_rf(dir)
  end

  private

  def free_port
    server = TCPServer.new('127.0.0.1', 0)

    server.addr[1]
  ensure
    server.close
  end

  def wait_for_port
    host, port = addr.split(':')

    200.times do
      TCPSocket.new(host, port).close

      return
    rescue SystemCallError
      sleep 0.01
    end

    raise 'server did not start'
  end
end

module ServerHelpers
  def start_server(env = {})
    skip 'SERVER_BIN is not set' unless ENV['SERVER_BIN']

    TestServer.new(env).tap { |server| servers << server }
  end

  def servers
    @servers ||= []
  end

  def clients
    @clients ||= []
  end

  def open_client(url, **options)
    Anway::Client.new(url, wid: SecureRandom.hex(6), **options).tap { |client| clients << client }
  end

  def cleanup_servers
    clients.each(&:close)
    threads.each { |thread| thread.kill }
    servers.each(&:cleanup)
  end

  def threads
    @threads ||= []
  end

  def run_in_thread(runner)
    Thread.new { runner.run }.tap { |thread| threads << thread }
  end

  def wait_for(limit = 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + limit

    until yield
      raise 'condition was not met' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
  end

  def retries(client)
    client.info.dig('faktory', 'tasks', 'Retries', 'size')
  end

  def processed(client)
    client.info.dig('faktory', 'total_processed')
  end
end
