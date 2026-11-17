# frozen_string_literal: true

require 'net/http'
require 'socket'

# Cron entries that the app declares, and the SCHEDULE scenarios S01 to S03.
RSpec.describe 'schedules' do
  def free_web
    "127.0.0.1:#{TCPServer.new('127.0.0.1', 0).then { |socket| socket.addr[1].tap { socket.close } }}"
  end

  def web_server
    @web = free_web

    start_server('WEB_ADDR' => @web, 'WEB_TOKEN' => 't')
  end

  # The client cron entries of a tag, as GET /api/v1/schedules shows them.
  def cron_of(tag)
    api = Net::HTTP.new(*@web.split(':').then { |host, port| [host, port.to_i] })
    body = api.get('/api/v1/schedules', 'Authorization' => 'Bearer t').body

    JSON.parse(body)['cron'].select { |entry| entry['source'] == 'client' && entry['tag'] == tag }
  end

  def entry(schedule, type, **job)
    { schedule: schedule, job: { type: type, queue: 'billing', retry: 3, **job } }
  end

  # A job class with cron that is registered only in this example, so the
  # runners of other specs do not send its entries.
  def cron_job(name, **options)
    klass = Class.new do
      include Anway::Worker

      def perform; end
    end

    stub_const(name, klass)

    klass.anway_options(**options)

    Anway::Worker.register(klass)
    registered << klass.anway_options[:event]

    klass
  end

  def registered
    @registered ||= []
  end

  after do
    registry = Anway::Worker.instance_variable_get(:@registry)

    registered.each { |event| registry.delete(event) }
  end

  it 'S01 replaces the entries of a tag, and unschedule removes it' do
    server = web_server
    client = open_client(server.url)

    expect(client.schedule('shop', [entry('0 0 * * *', 'credits.refill'), entry('*/5 * * * *', 'report')])).to be(true)

    client.schedule('shop', [entry('0 0 * * *', 'credits.refill')])

    expect(cron_of('shop')).to match([
      include('schedule' => '0 0 * * *', 'jobtype' => 'credits.refill', 'queue' => 'billing', 'source' => 'client', 'tag' => 'shop')
    ])

    client.schedule('shop', [])

    expect(cron_of('shop')).to be_empty

    client.schedule('shop', [{ 'schedule' => '0 0 * * *', 'job' => { 'event' => 'credits.refill' } }])

    expect(cron_of('shop').map { |item| item['jobtype'] }).to eq(['credits.refill'])

    2.times { expect(client.unschedule('shop')).to be(true) }

    expect(cron_of('shop')).to be_empty
  end

  it 'S02 refuses a bad schedule or an entry with no job type, and changes nothing' do
    server = web_server
    client = open_client(server.url)

    client.schedule('shop', [entry('0 0 * * *', 'credits.refill')])

    expect { client.schedule('shop', [entry('0 0 * * *', 'report'), entry('not a schedule', 'other')]) }.to raise_error(Anway::ServerError, /invalid schedule/)
    expect { client.schedule('shop', [{ schedule: '0 0 * * *', job: { queue: 'billing' } }]) }.to raise_error(Anway::ServerError, /no job type/)
    expect { client.schedule('', [entry('0 0 * * *', 'report')]) }.to raise_error(Anway::ServerError, /invalid tag/)
    expect { client.schedule('shop', ['0 0 * * *']) }.to raise_error(ArgumentError)

    expect(cron_of('shop').map { |item| item['jobtype'] }).to eq(['credits.refill'])
  end

  it 'S03 sends the cron of the job classes and of the config in one SCHEDULE at start' do
    server = web_server

    cron_job('RefillJob', event: 'credits.refill', queue: 'billing', retry: 3, cron: '0 0 * * *')
    cron_job('ReportJob', cron: ['*/5 * * * *', '0 12 * * *'])

    config = [{ 'schedule' => '0 6 * * *', 'job' => { 'type' => 'cleanup', 'queue' => 'ops' } }]
    log = StringIO.new
    current = Anway::Runner.new(url: server.url, concurrency: 1, tag: 'shop', cron: Anway::Worker.cron_entries + config, logger: Logger.new(log))

    run_in_thread(current)

    wait_for { log.string.include?('anway started') }

    expect(log.string).to include('anway scheduled tag=shop cron=4')

    expect(cron_of('shop').map { |item| item.values_at('schedule', 'jobtype', 'queue') }).to eq([
      ['0 0 * * *', 'credits.refill', 'billing'],
      ['*/5 * * * *', 'ReportJob', 'default'],
      ['0 12 * * *', 'ReportJob', 'default'],
      ['0 6 * * *', 'cleanup', 'ops']
    ])
  end

  it 'S03 does not start with cron entries and no tag' do
    server = start_server

    cron_job('NightlyJob', cron: '0 0 * * *')

    expect { Anway::Runner.new(url: server.url, concurrency: 1).run }.to raise_error(ArgumentError, /no tag/)
  end

  it 'sends no SCHEDULE without cron entries, so the entries of another process stay' do
    server = web_server

    open_client(server.url).schedule('shop', [entry('0 0 * * *', 'credits.refill')])

    log = StringIO.new
    current = Anway::Runner.new(url: server.url, concurrency: 1, tag: 'shop', logger: Logger.new(log))

    run_in_thread(current)

    wait_for { log.string.include?('anway started') }

    expect(log.string).not_to include('anway scheduled')
    expect(cron_of('shop').size).to eq(1)
  end

  it 'builds the entries of a class from its declaration, and does not pass cron to a subclass' do
    parent = cron_job('BillingJob', event: 'billing.run', queue: 'billing', retry: 2, reserve_for: 120, cron: '0 1 * * *')

    parent.anway_options cron: ['0 1 * * *', '0 2 * * *']

    expect(parent.cron_entries).to eq([
      { 'schedule' => '0 1 * * *', 'job' => { 'type' => 'billing.run', 'queue' => 'billing', 'retry' => 2, 'reserve_for' => 120 } },
      { 'schedule' => '0 2 * * *', 'job' => { 'type' => 'billing.run', 'queue' => 'billing', 'retry' => 2, 'reserve_for' => 120 } }
    ])

    child = Class.new(parent)

    expect(child.cron_entries).to eq([])
  end

  it 'lists the declared cron with Anway.cron, and keeps schedules in the test modes' do
    cron_job('RefillJob', event: 'credits.refill', cron: '0 0 * * *')

    settings = Anway::Settings.new({ 'tag' => 'shop', 'cron' => [{ 'schedule' => '0 6 * * *', 'job' => { 'type' => 'cleanup' } }] }, environment: 'test', env: {})

    expect(Anway.cron(settings)).to include(
      { 'schedule' => '0 0 * * *', 'job' => { 'type' => 'credits.refill', 'queue' => 'default' } },
      { 'schedule' => '0 6 * * *', 'job' => { 'type' => 'cleanup' } }
    )

    Anway::Testing.fake!

    Anway.schedule('shop', [{ schedule: '0 0 * * *', job: { event: 'credits.refill' } }])

    expect(Anway::Testing.schedules).to eq('shop' => [{ 'schedule' => '0 0 * * *', 'job' => { 'type' => 'credits.refill' } }])

    Anway.unschedule('shop')

    expect(Anway::Testing.schedules).to eq({})
  end

  it 'reads cron from config/anway.yml, and refuses a value that is not a list of entries' do
    settings = Anway::Settings.new({ 'cron' => [{ 'schedule' => '0 0 * * *', 'job' => { 'type' => 'a' } }], 'test' => { 'cron' => [] } }, environment: 'test', env: {})

    expect(settings.cron).to eq([])

    expect { Anway::Settings.new({ 'cron' => 'nope' }, environment: 'test', env: {}) }.to raise_error(ArgumentError, /list of entries/)
    expect { Anway::Settings.new({ 'cron' => [{ 'schedule' => '0 0 * * *' }] }, environment: 'test', env: {}) }.to raise_error(ArgumentError, /job hash/)
  end
end
