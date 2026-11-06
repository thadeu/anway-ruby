# frozen_string_literal: true

require 'json'

module Anway
  # InspectCommand prints `anway jobs` and `anway job <jid>`.
  #
  #   anway jobs                                 one line for each set
  #   anway jobs --set retries --type EmitInvoice
  #   anway job a1b2c3d4 [--full]
  #   --json prints the API answer, for scripts and agents
  class InspectCommand
    BACKTRACE = 3

    def initialize(api, out: $stdout, now: Time.now)
      @api = api
      @out = out
      @now = now
    end

    def summary(json: false)
      summary = Inspect.summary(@api)

      return print_json(summary.to_h) if json

      summary.sets.each { |line| @out.puts(summary_line(line)) }
    end

    def list(set:, type: nil, queue: nil, limit: 20, json: false)
      infos = Inspect::Jobs.new(@api, set: set, type: type, queue: queue).first(limit)

      return print_json(infos.map(&:to_h)) if json
      return @out.puts("no #{set} jobs#{" of #{type}" if type}") if infos.empty?

      rows = infos.map { |info| [short(info.jid), info.name, info.queue, try(info), when_of(info), error_line(info)] }

      table(%w[JID TYPE QUEUE TRY NEXT ERROR], rows)
    end

    # Returns false when the job is not found.
    def show(jid, full: false, json: false)
      reply = @api.job(jid)

      unless reply
        warn("anway: not found: it finished, or it never existed (#{jid})")

        return false
      end

      return print_json(reply) || true if json

      describe(JobInfo.from_api(reply['job'], set: reply['set']), full)

      true
    end

    private

    def summary_line(line)
      parts = [line[:set].ljust(9), line[:count].to_s.rjust(4)]

      parts << "oldest #{ago(line[:oldest])}" if line[:set] == 'waiting' && line[:oldest]
      parts << top_line(line[:top], line[:set] == 'working' ? line[:worker] : nil) if line[:top]
      parts << line[:error][:value] if line[:error]

      parts.join('   ')
    end

    def top_line(top, worker)
      text = top[:count] > 1 ? "#{top[:value]} ×#{top[:count]}" : top[:value]

      worker ? "#{text} on #{worker[:value]}" : text
    end

    def describe(info, full)
      label = info.wrapped ? "#{info.wrapped} (Active Job, wrapper #{info.type})" : info.type

      @out.puts(label)

      field('state', state_text(info))
      field('queue', info.queue)
      field('args', JSON.generate(info.args))
      field('custom', JSON.generate(info.custom)) unless info.custom.empty?
      field('enqueued', clock(info.enqueued_at)) if info.enqueued_at
      field('started', "#{clock(info.started_at)} on #{info.worker}") if info.started_at

      error(info.error, full) if info.error
    end

    def error(error, full)
      field('error', "#{error[:class]}: #{error[:message]}")

      lines = full ? error[:backtrace] : error[:backtrace].first(BACKTRACE)

      lines.each { |line| @out.puts("          #{line}") }

      rest = error[:backtrace].size - lines.size

      @out.puts("          (#{rest} lines more, --full shows all)") if rest.positive?
    end

    def state_text(info)
      return info.state unless %w[retries scheduled].include?(info.state) && info.next_at

      "#{info.state} (#{"try #{info.retry_count}, " if info.retry_count.positive?}next run #{clock(info.next_at)})"
    end

    def field(name, value) = @out.puts("#{name.ljust(9)} #{value}")

    def table(headers, rows)
      widths = headers.each_index.map { |i| ([headers[i]] + rows.map { |row| row[i].to_s }).map(&:length).max }

      [headers, *rows].each { |row| @out.puts(row.each_with_index.map { |cell, i| cell.to_s.ljust(widths[i]) }.join('  ').rstrip) }
    end

    def short(jid) = jid.to_s[0, 8]

    def try(info) = info.retry_count.positive? ? info.retry_count.to_s : '-'

    def when_of(info) = info.next_at ? "in #{seconds(info.next_at - @now)}" : '-'

    def error_line(info) = info.error ? "#{info.error[:class]}: #{info.error[:message]}"[0, 60] : ''

    def ago(time) = seconds(@now - time)

    def seconds(value)
      value = value.round

      return "#{value}s" if value.abs < 120
      return "#{value / 60}m" if value.abs < 7200

      "#{value / 3600}h"
    end

    def clock(time) = time.localtime.strftime('%H:%M:%S')

    def print_json(value)
      @out.puts(JSON.pretty_generate(value))

      nil
    end
  end
end
