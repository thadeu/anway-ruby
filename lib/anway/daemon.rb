# frozen_string_literal: true

require 'socket'

module Anway
  # Daemon runs a binary as a child process: the server or the console. A
  # subclass names the binary, its address, and its environment.
  class Daemon
    START_TIMEOUT = 15
    STOP_TIMEOUT = 40
    LOCAL_HOSTS = ['', '0.0.0.0', '::', '[::]'].freeze

    attr_reader :pid

    def self.local_host(host)
      LOCAL_HOSTS.include?(host) ? '127.0.0.1' : host
    end

    def initialize(settings, logger: Anway.config.logger)
      @settings = settings
      @logger = logger
    end

    # Starts the binary and waits for its port. When a process already
    # listens on the address, it uses that one and returns false. With a
    # random web token, that process has another token, so the start fails.
    def start
      if listening?
        raise Error, "a #{name} already listens on #{address} with another web token. Stop it, or set server.web_token in config/anway.yml." if @settings.random_web_token?

        @logger.info("anway: a #{name} already listens on #{address}, so this process uses it")

        return false
      end

      prepare

      @pid = Process.spawn(env, executable)

      wait_for_port
      announce

      true
    end

    # Runs the binary in this process. It does not return.
    def exec
      prepare
      announce

      Process.exec(env, executable)
    end

    # Asks the process to stop, and kills it after STOP_TIMEOUT.
    def stop
      return unless @pid

      Process.kill('TERM', @pid)

      return if wait(STOP_TIMEOUT)

      Process.kill('KILL', @pid)
      wait(5)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    ensure
      @pid = nil
    end

    private

    def prepare; end

    def wait_for_port
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + START_TIMEOUT

      until listening?
        raise Error, "the anway #{name} stopped at start with #{$? || 'an error'}" if exited?
        raise Error, "the anway #{name} did not open #{address} in #{START_TIMEOUT} seconds" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.05
      end
    end

    def listening?
      host, _, port = address.rpartition(':')

      Socket.tcp(self.class.local_host(host), port.to_i, connect_timeout: 0.2).close

      true
    rescue SystemCallError, SocketError
      false
    end

    def exited?
      Process.wait(@pid, Process::WNOHANG) == @pid
    rescue Errno::ECHILD
      true
    end

    def wait(seconds)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds

      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        return true if Process.wait(@pid, Process::WNOHANG)

        sleep 0.05
      end

      false
    rescue Errno::ECHILD
      true
    end
  end
end
