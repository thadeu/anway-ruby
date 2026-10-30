# frozen_string_literal: true

module Anway
  # Connections open at first use. A forked process starts with an empty pool
  # and does not touch the sockets of its parent.
  class Pool
    # A wrapper, because a pop timeout also returns nil.
    Slot = Data.define(:connection)

    def initialize(size, &opener)
      @size = size
      @opener = opener
      @lock = Mutex.new
      @closed = false

      reset
    end

    def with(timeout:)
      connection = checkout(timeout)
      healthy = false

      begin
        connection ||= @opener.call

        result = yield connection
        healthy = true

        result
      rescue ServerError, NotUnique
        healthy = true

        raise
      ensure
        checkin(connection, healthy)
      end
    end

    def close
      @lock.synchronize do
        return if @closed

        @closed = true
      end

      @slots.close

      @size.times do
        @slots.pop(timeout: 1)&.connection&.close
      end
    end

    private

    def reset
      @pid = Process.pid
      @slots = Thread::SizedQueue.new(@size)

      @size.times { @slots.push(Slot.new(nil)) }
    end

    def checkout(timeout)
      raise Closed if @closed

      @lock.synchronize { reset unless @pid == Process.pid }

      entry = @slots.pop(timeout: timeout)

      raise Closed if entry.nil? && @slots.closed?
      raise ConnectionError, 'no free connection' if entry.nil?

      entry.connection
    end

    def checkin(connection, healthy)
      connection&.close unless healthy

      return connection&.close if @slots.closed?

      @slots.push(Slot.new(healthy ? connection : nil))
    rescue ClosedQueueError
      connection&.close
    end
  end
end
