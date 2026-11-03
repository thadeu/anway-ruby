# frozen_string_literal: true

require 'puma/plugin'
require 'anway'
require 'anway/puma/plugin'

# `plugin :anway` in config/puma.rb runs bin/anway next to Puma, as
# config/anway.yml says: the embedded server and the workers, or only the
# workers. ANWAY_IN_PUMA turns it on or off. Without it, it runs only in
# development. When anway stops by itself, Puma stops too, so a broken worker
# is not hidden.
Puma::Plugin.create do
  def start(launcher)
    @launcher = launcher

    return unless Anway::Puma::Plugin.enabled?

    events = launcher.events

    if events.respond_to?(:after_booted)
      events.after_booted { start_anway }
      events.after_stopped { stop_anway }
      events.before_restart { stop_anway }
    else
      events.on_booted { start_anway }
      events.on_stopped { stop_anway }
      events.on_restart { stop_anway }
    end
  end

  private

  def start_anway
    @stopping = false
    @pid = Process.spawn(*Anway::Puma::Plugin.command)

    @monitor = Thread.new(@pid) do |pid|
      _, status = Process.wait2(pid)

      unless @stopping
        log("anway stopped with #{status}, so Puma stops")
        @launcher.stop
      end
    end

    log("anway started with pid #{@pid}")
  end

  def stop_anway
    return unless @pid

    @stopping = true

    Process.kill('TERM', @pid)

    Process.kill('KILL', @pid) unless @monitor.join(Anway::Server::STOP_TIMEOUT + 5)
    @monitor.join(5)
  rescue Errno::ESRCH
    nil
  ensure
    @pid = nil
  end

  def log(message)
    writer = @launcher.respond_to?(:log_writer) ? @launcher.log_writer : @launcher.events

    writer.log("* #{message}")
  end
end
