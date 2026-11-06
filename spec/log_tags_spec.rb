# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'active_support'
require 'active_support/logger'
require 'active_support/tagged_logging'

class TaggedLogJob
  include Anway::Worker

  anway_options event: 'tagged.log'

  def perform(message, wait = 0)
    sleep(wait)

    Anway.config.logger.info("inside #{message}")
  end
end

class FailingLogJob
  include Anway::Worker

  anway_options event: 'failing.log'

  def perform
    raise ArgumentError, 'bad input'
  end
end

RSpec.describe 'job tags on log lines' do
  let(:io) { StringIO.new }
  let(:tagged) { ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(io)) }
  let(:runner) { Anway::Runner.new(logger: tagged) }

  around do |example|
    saved = Anway.config.logger

    Anway.config.logger = tagged
    example.run
  ensure
    Anway.config.logger = saved
    Anway.config.log_tags = true
  end

  def job(type, args, **hash)
    Anway::Job.from_hash({ 'jid' => "jid-#{args.first}", 'jobtype' => type, 'args' => args }.merge(hash))
  end

  def perform(job) = runner.send(:perform, job)

  it 'tags the lines of a job, and not the lines after it' do
    perform(job('tagged.log', ['one']))

    tagged.info('outside')

    expect(io.string).to include('[anway tagged.log jid=jid-one try=1] inside one')
    expect(io.string).to match(/anway done   tagged\.log jid=jid-one \d+ms/)
    expect(io.string.lines.last).to eq("outside\n")
  end

  it 'names the Active Job class and the try' do
    perform(job('tagged.log', ['two'], 'custom' => { 'wrapped' => 'EmitInvoiceJob' }, 'failure' => { 'retry_count' => 1 }))

    expect(io.string).to include('[anway EmitInvoiceJob jid=jid-two try=3] inside two')
  end

  it 'keeps the tag of each job on its own thread' do
    first = Thread.new { perform(job('tagged.log', ['a', 0.2])) }
    second = Thread.new { perform(job('tagged.log', ['b', 0.1])) }

    [first, second].each(&:join)

    expect(io.string).to include('[anway tagged.log jid=jid-a try=1] inside a', '[anway tagged.log jid=jid-b try=1] inside b')
    expect(io.string).not_to include('jid=jid-a try=1] [anway')
  end

  it 'logs a failure with what the server does next' do
    retry_job = Anway::Job.from_hash('jid' => 'f1', 'jobtype' => 'failing.log', 'args' => [])
    last = Anway::Job.from_hash('jid' => 'f2', 'jobtype' => 'failing.log', 'args' => [], 'retry' => 2, 'failure' => { 'retry_count' => 1 })
    discard = Anway::Job.from_hash('jid' => 'f3', 'jobtype' => 'failing.log', 'args' => [], 'retry' => 0)
    straight = Anway::Job.from_hash('jid' => 'f4', 'jobtype' => 'failing.log', 'args' => [], 'retry' => -1)

    [retry_job, last, discard, straight].each { |one| expect(perform(one)).to be_a(ArgumentError) }

    expect(io.string).to match(/anway failed failing\.log jid=f1 try=1 ArgumentError: bad input \(retry\) \d+ms/)
    expect(io.string).to include('jid=f2 try=3 ArgumentError: bad input (dead)', 'jid=f3 try=1 ArgumentError: bad input (discarded)', 'jid=f4 try=1 ArgumentError: bad input (dead)')
  end

  it 'adds no tags with log_tags off, or with a logger without tags' do
    Anway.config.log_tags = false

    perform(job('tagged.log', ['three']))

    plain_io = StringIO.new
    plain = Logger.new(plain_io)

    Anway.config.log_tags = true
    Anway.config.logger = plain
    Anway::Runner.new(logger: plain).send(:perform, job('tagged.log', ['four']))

    expect(io.string).to include("inside three\n")
    expect(io.string).not_to include('[anway')
    expect(plain_io.string).to include('inside four', 'anway done   tagged.log jid=jid-four')
  end

  it 'reads log_tags from config/anway.yml' do
    expect(Anway::Settings.new({}, environment: 'development', env: {})).to be_log_tags
    expect(Anway::Settings.new({ 'log_tags' => false }, environment: 'development', env: {})).not_to be_log_tags
  end
end
