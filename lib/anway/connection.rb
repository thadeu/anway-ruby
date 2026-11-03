# frozen_string_literal: true

require 'digest'
require 'json'
require 'openssl'
require 'socket'

module Anway
  # One socket. Timeouts use nonblocking calls, so that plain and TLS sockets
  # follow the same path.
  class Connection
    PROTOCOL_VERSION = 2
    READ_SIZE = 16_384

    # identity holds more HELLO fields of a worker, such as tag, queues, and
    # concurrency. Its hostname replaces the machine name.
    def initialize(endpoint, timeout:, tls: nil, wid: nil, labels: [], identity: {})
      @timeout = timeout
      @buffer = String.new(encoding: Encoding::BINARY)
      @io = open_socket(endpoint, tls)

      handshake(endpoint, wid, labels, identity)
    rescue StandardError
      close

      raise
    end

    # The argument is a string, or an object that becomes JSON.
    def command(verb, argument = nil, wait: 0)
      deadline = monotonic + @timeout + wait
      line = argument.nil? ? verb : "#{verb} #{argument.is_a?(String) ? argument : JSON.generate(argument)}"

      write_all("#{line}\r\n", deadline)
      read_reply(deadline)
    rescue SystemCallError, IOError, SocketError, OpenSSL::SSL::SSLError => e
      raise ConnectionError, e.message
    end

    def close
      @io&.close
    rescue SystemCallError, IOError, OpenSSL::SSL::SSLError
      nil
    ensure
      @io = nil
    end

    private

    def open_socket(endpoint, tls)
      socket = Socket.tcp(endpoint.host, endpoint.port, connect_timeout: @timeout, resolv_timeout: @timeout)

      return socket unless endpoint.tls

      wrap_tls(socket, endpoint.host, tls)
    rescue SystemCallError, SocketError, OpenSSL::SSL::SSLError => e
      raise ConnectionError, e.message
    end

    def wrap_tls(socket, host, tls)
      context = OpenSSL::SSL::SSLContext.new

      context.set_params(tls || {})

      secure = OpenSSL::SSL::SSLSocket.new(socket, context)

      secure.hostname = host
      secure.sync_close = true

      connect_tls(secure)

      secure
    end

    def connect_tls(secure)
      deadline = monotonic + @timeout

      loop do
        case secure.connect_nonblock(exception: false)
        when :wait_readable then wait(secure, deadline, :read)
        when :wait_writable then wait(secure, deadline, :write)
        else return
        end
      end
    end

    def handshake(endpoint, wid, labels, identity)
      deadline = monotonic + @timeout
      greeting = JSON.parse(read_reply(deadline).delete_prefix('HI '))

      raise Error, "unsupported protocol version #{greeting['v']}" unless greeting['v'] == PROTOCOL_VERSION

      hello = { v: PROTOCOL_VERSION }

      if greeting['s']
        hello[:pwdhash] = password_hash(endpoint.password.to_s, greeting['s'], greeting['i'])
      end

      if wid
        hello.merge!(wid: wid, hostname: Socket.gethostname, pid: Process.pid, labels: labels, **identity.compact)
      end

      command('HELLO', hello)
    end

    def password_hash(password, salt, iterations)
      digest = Digest::SHA256.digest(password + salt)

      (iterations - 1).times { digest = Digest::SHA256.digest(digest) }

      digest.unpack1('H*')
    end

    def write_all(data, deadline)
      data = data.b

      until data.empty?
        written = @io.write_nonblock(data, exception: false)

        case written
        when :wait_readable then wait(@io, deadline, :read)
        when :wait_writable then wait(@io, deadline, :write)
        else data = data.byteslice(written..)
        end
      end
    end

    def read_reply(deadline)
      line = read_line(deadline)

      raise ConnectionError, 'empty reply' if line.empty?

      body = line[1..]

      case line[0]
      when '+' then body.force_encoding(Encoding::UTF_8)
      when '-' then raise server_error(body)
      when '$' then read_bulk(Integer(body), deadline)
      else raise ConnectionError, "unexpected reply: #{line.inspect}"
      end
    end

    def server_error(body)
      code, message = body.force_encoding(Encoding::UTF_8).split(' ', 2)

      return NotUnique.new if code == 'NOTUNIQUE'

      ServerError.new(code, message)
    end

    def read_line(deadline)
      until (index = @buffer.index("\n"))
        fill(deadline)
      end

      @buffer.slice!(0..index).chomp
    end

    def read_bulk(size, deadline)
      return nil if size.negative?

      fill(deadline) while @buffer.bytesize < size + 2

      body = @buffer.slice!(0, size)

      @buffer.slice!(0, 2)

      body.force_encoding(Encoding::UTF_8)
    end

    def fill(deadline)
      chunk = @io.read_nonblock(READ_SIZE, exception: false)

      case chunk
      when :wait_readable then wait(@io, deadline, :read)
      when :wait_writable then wait(@io, deadline, :write)
      when nil then raise ConnectionError, 'server closed the connection'
      else @buffer << chunk
      end
    end

    def wait(io, deadline, mode)
      remaining = deadline - monotonic

      raise ConnectionError, 'timeout' unless remaining.positive?

      readers = mode == :read ? [io] : nil
      writers = mode == :write ? [io] : nil

      IO.select(readers, writers, nil, remaining)
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
