# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'anway/cli'

RSpec.describe 'inspecting jobs' do
  let(:token) { 'inspect-token' }
  let(:web) { "127.0.0.1:#{free_port}" }
  let(:server) { start_server('WEB_ADDR' => web, 'WEB_TOKEN' => token) }
  let(:client) { Anway::Client.new(server.url, wid: 'inspect-worker') }
  let(:api) { Anway::Api.new(url: "http://#{web}", token: token) }

  def free_port
    tcp = TCPServer.new('127.0.0.1', 0)
    tcp.addr[1]
  ensure
    tcp&.close
  end

  def push(type, queue: 'default', at: nil, custom: nil, retry_count: nil)
    job = Anway::Job.new(type, [42], queue: queue, at: at, custom: custom, retry: retry_count)

    client.push(job)

    job.jid
  end

  def fail_one(queue, message)
    job = client.fetch(queue)

    client.fail(job.jid, errtype: 'Net::ReadTimeout', message: message, backtrace: Array.new(12) { |i| "app/x.rb:#{i}" })

    job.jid
  end

  after { client.close }

  describe 'Anway.job' do
    before { Anway.api = api }

    it 'finds a job in each set, and nil after it finishes' do
      waiting = push('mail.send')
      scheduled = push('mail.send', at: Time.now + 3600)

      expect(Anway.job(waiting)).to have_attributes(state: 'waiting', type: 'mail.send', args: [42], queue: 'default')
      expect(Anway.job(scheduled)).to have_attributes(state: 'scheduled', next_at: be > Time.now)

      running = client.fetch('default')

      expect(Anway.job(running.jid)).to have_attributes(state: 'working', worker: be_a(String), started_at: be_a(Time))

      client.ack(running.jid)

      expect(Anway.job(running.jid)).to be_nil
      expect(Anway.job('never-existed')).to be_nil
    end

    it 'shows the error, the try and the backtrace of a failed job' do
      push('EmitInvoice', queue: 'q1')

      jid = fail_one('q1', 'execution expired')
      info = Anway.job(jid)

      expect(info.state).to eq('retries')
      expect(info.retry_count).to eq(1)
      expect(info.error).to include(class: 'Net::ReadTimeout', message: 'execution expired')
      expect(info.error[:backtrace].size).to eq(12)
    end

    it 'names the Active Job class of a wrapped job' do
      jid = push('Anway::ActiveJobWrapper', custom: { 'wrapped' => 'EmitInvoiceJob' })

      expect(Anway.job(jid)).to have_attributes(type: 'Anway::ActiveJobWrapper', wrapped: 'EmitInvoiceJob', name: 'EmitInvoiceJob')
    end
  end

  describe 'Anway.jobs' do
    before { Anway.api = api }

    it 'lists a set, filtered by a part of the type or the wrapped class' do
      push('Anway::ActiveJobWrapper', custom: { 'wrapped' => 'EmitInvoiceJob' })
      push('report.build')

      expect(Anway.jobs(set: :waiting).map(&:name)).to contain_exactly('EmitInvoiceJob', 'report.build')
      expect(Anway.jobs(set: :waiting, type: 'EmitInvoice').map(&:name)).to eq(['EmitInvoiceJob'])
      expect(Anway.jobs(set: 'queue:default', type: 'report').map(&:name)).to eq(['report.build'])
    end

    it 'reads one page at a time' do
      7.times { push('mail.send') }

      jobs = Anway::Inspect::Jobs.new(api, set: :waiting, page: 2)

      allow(api).to receive(:jobs).and_call_original

      expect(jobs.first(3).size).to eq(3)
      expect(api).to have_received(:jobs).twice
    end

    it 'sums up each set' do
      push('mail.send')
      push('EmitInvoice', queue: 'q1')
      fail_one('q1', 'boom')

      summary = Anway.jobs

      expect(summary['waiting']).to include(count: 1, top: { value: 'mail.send', count: 1 })
      expect(summary['retries']).to include(count: 1, error: { value: 'Net::ReadTimeout: boom', count: 1 })
      expect(summary['dead']).to include(count: 0, top: nil)
    end
  end

  describe 'with Anway::Testing.fake!' do
    before { Anway::Testing.fake! }

    it 'reads the fake jobs' do
      jid = Anway.push('mail.send', [1])

      expect(Anway.job(jid)).to have_attributes(state: 'waiting', type: 'mail.send')
      expect(Anway.job('other')).to be_nil
      expect(Anway.jobs(set: :waiting, type: 'mail').map(&:jid)).to eq([jid])
      expect(Anway.jobs(set: :retries).to_a).to be_empty
      expect(Anway.jobs['waiting'][:count]).to eq(1)
    end
  end

  describe 'Anway::Api' do
    it 'says when no server answers, without a stack trace' do
      expect { Anway::Api.new(url: "http://#{web}").overview }.to raise_error(Anway::Api::Unreachable, "no server at http://#{web} (is bin/dev running?)")
    end

    it 'refuses a wrong token' do
      server

      expect { Anway::Api.new(url: "http://#{web}", token: 'wrong').overview }.to raise_error(Anway::Error, /answered 401/)
    end

    it 'finds the API from the settings, and asks for one when there is none' do
      external = Anway::Settings.new({ 'url' => 'tcp://x:7419' }, environment: 'development', env: {})

      expect { Anway::Api.from_settings(external) }.to raise_error(Anway::Api::Unreachable, /ANWAY_API_URL/)

      env = Anway::Settings.new({ 'url' => 'tcp://x:7419' }, environment: 'development', env: { 'ANWAY_API_URL' => 'http://h:7420', 'ANWAY_WEB_TOKEN' => 't' })

      expect(Anway::Api.from_settings(env).url).to eq('http://h:7420')
    end
  end

  describe 'anway jobs and anway job' do
    let(:out) { StringIO.new }
    let(:command) { Anway::InspectCommand.new(api, out: out) }

    it 'prints one line for each set' do
      push('mail.send')
      push('EmitInvoice', queue: 'q1')
      fail_one('q1', 'execution expired')

      command.summary

      expect(out.string.lines.map { |line| line.split.first }).to eq(%w[waiting working retries scheduled dead])
      expect(out.string).to match(/^waiting\s+1\s+oldest \d+s\s+mail\.send$/)
      expect(out.string).to match(/^retries\s+1\s+EmitInvoice\s+Net::ReadTimeout: execution expired$/)
    end

    it 'prints a table of a set' do
      push('EmitInvoice', queue: 'q1')
      jid = fail_one('q1', 'execution expired')

      command.list(set: 'retries', type: 'Emit')

      header, row = out.string.lines

      expect(header.split).to eq(%w[JID TYPE QUEUE TRY NEXT ERROR])
      expect(row).to start_with(jid[0, 8])
      expect(row).to include('EmitInvoice', 'q1', 'Net::ReadTimeout: execution expired')
    end

    it 'says when a set has no jobs' do
      server

      command.list(set: 'dead', type: 'X')

      expect(out.string).to eq("no dead jobs of X\n")
    end

    it 'prints one job with three backtrace lines, or all with --full' do
      push('EmitInvoice', queue: 'q1')
      jid = fail_one('q1', 'execution expired')

      expect(command.show(jid)).to be(true)
      expect(out.string).to include("state     retries (try 1, next run", 'error     Net::ReadTimeout: execution expired', 'app/x.rb:2', '(9 lines more, --full shows all)')
      expect(out.string).not_to include('app/x.rb:3')

      out.truncate(0)
      out.rewind
      command.show(jid, full: true)

      expect(out.string).to include('app/x.rb:11')
    end

    it 'prints the API answer with --json' do
      jid = push('mail.send')

      command.show(jid, json: true)

      expect(JSON.parse(out.string)).to include('set' => 'waiting')

      out.truncate(0)
      out.rewind
      command.list(set: 'waiting', json: true)

      expect(JSON.parse(out.string).first).to include('jid' => jid, 'state' => 'waiting')

      out.truncate(0)
      out.rewind
      command.summary(json: true)

      expect(JSON.parse(out.string)['sets'].first).to include('set' => 'waiting', 'count' => 1)
    end

    it 'says a finished job is not found' do
      server

      expect { expect(command.show('gone')).to be(false) }.to output(/not found: it finished, or it never existed/).to_stderr
    end

    it 'exits 1 with a short message when no server answers' do
      cli = Anway::CLI.new(['jobs'])

      allow(Anway::Api).to receive(:from_settings).and_return(Anway::Api.new(url: "http://#{web}"))

      expect { expect(cli.run).to eq(1) }.to output("anway: no server at http://#{web} (is bin/dev running?)\n").to_stderr
    end

    it 'runs anway job and anway jobs --set from the command line' do
      jid = push('mail.send')

      allow(Anway::Api).to receive(:from_settings).and_return(api)

      expect { expect(Anway::CLI.new(['job', jid]).run).to eq(0) }.to output(/^mail\.send\nstate     waiting/).to_stdout
      expect { expect(Anway::CLI.new(%w[jobs --set waiting --type mail]).run).to eq(0) }.to output(/mail\.send/).to_stdout
      expect { expect(Anway::CLI.new(%w[job missing]).run).to eq(1) }.to output(/not found/).to_stderr
      expect { expect(Anway::CLI.new(['job']).run).to eq(2) }.to output(/needs a jid/).to_stderr
    end
  end
end
