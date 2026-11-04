# frozen_string_literal: true

class NamedJob
  include Anway::Worker

  anway_options event: 'email.send', queue: 'mailers', retry: 5, custom: { unique_for: 60 }

  class << self
    attr_accessor :received
  end

  def perform(address)
    self.class.received = [address, jid]
  end
end

class ChildJob < NamedJob
  anway_options event: 'child.job', retry: 1
end

class RoomMessageJob
  include Anway::Worker

  anway_options event: 'chat.broadcast', queue: 'realtime', retry: 2, reserve_for: 120
  anway_options topics: %w[chat.message chat.edited chat.message]

  class << self
    attr_accessor :received
  end

  def perform(message)
    (self.class.received ||= []) << [message, job.custom]
  end
end

class LateMessageJob < RoomMessageJob
end

class PlainSubscriberJob
  include Anway::Worker

  anway_options topics: 'chat.message'

  def perform(_message); end
end

RSpec.describe Anway::Worker do
  before { Anway::Testing.fake! }

  it 'builds the job from the class options' do
    NamedJob.perform_async('a@b.com')

    job = Anway::Testing.jobs.first

    expect(job.type).to eq('email.send')
    expect(job.queue).to eq('mailers')
    expect(job.retry).to eq(5)
    expect(job.backtrace).to eq(30)
    expect(job.args).to eq(['a@b.com'])
    expect(job.custom).to eq('unique_for' => 60)
  end

  it 'finds the class by event only when it is registered' do
    expect(described_class.find('email.send')).to eq(NamedJob)
    expect(described_class.find('child.job')).to eq(ChildJob)
    expect(described_class.find('LateMessageJob')).to eq(LateMessageJob)
    expect { described_class.find('NamedJob') }.to raise_error(Anway::UnknownJob)
    expect { described_class.find('Kernel') }.to raise_error(Anway::UnknownJob)
  end

  it 'uses the class name as the default event' do
    expect(PlainSubscriberJob.anway_options[:event]).to eq('PlainSubscriberJob')
  end

  it 'inherits all options except event and topics' do
    expect(ChildJob.anway_options).to eq(
      event: 'child.job', topics: [], queue: 'mailers', retry: 1, custom: { 'unique_for' => 60 }
    )

    expect(LateMessageJob.anway_options).to eq(
      event: 'LateMessageJob', topics: [], queue: 'realtime', retry: 2, reserve_for: 120
    )
  end

  it 'schedules jobs' do
    NamedJob.perform_in(60, 'x')

    expect(Time.parse(Anway::Testing.jobs.last.at)).to be_within(5).of(Time.now + 60)
  end

  it 'changes options for one push' do
    NamedJob.set(queue: 'low', track: true).perform_async('x')

    job = Anway::Testing.jobs.last

    expect(job.queue).to eq('low')
    expect(job.retry).to eq(5)
    expect(job.custom).to eq('unique_for' => 60, 'track' => 1)
  end

  it 'rejects args that are not JSON types' do
    expect { NamedJob.perform_async(:symbol) }.to raise_error(ArgumentError)
    expect { NamedJob.perform_async(Time.now) }.to raise_error(ArgumentError)
    expect { NamedJob.perform_async(key: 1) }.to raise_error(ArgumentError)
  end

  it 'rejects an unknown key' do
    expect { Class.new { include Anway::Worker }.anway_options(queues: 'a') }.to raise_error(ArgumentError, /queues/)
    expect { Class.new { include Anway::Worker }.anway_options(at: Time.now) }.to raise_error(ArgumentError, /at/)
    expect { NamedJob.set(jobtype: 'x') }.to raise_error(ArgumentError, /jobtype/)
    expect { NamedJob.set(topics: %w[x]) }.to raise_error(ArgumentError, /topics/)
    expect { NamedJob.set(event: 'x') }.to raise_error(ArgumentError, /event/)
    expect { Anway::Job.new('x', [], type: 'y') }.to raise_error(ArgumentError, /type/)
    expect { Anway::Job.new('x', [], on_dead: { jobtype: 'y' }) }.to raise_error(ArgumentError, /jobtype/)
    expect { Class.new { include Anway::Worker }.anway_options(on_dead: { queue: 'y' }) }.to raise_error(ArgumentError, /event/)
    expect { Anway.push('x', [], wait: 1) }.to raise_error(ArgumentError, /wait/)
  end

  it 'pushes a job with no local class' do
    Anway.push('image.resize', [42], queue: 'media', expires_in: 300)

    expect(Anway::Testing.jobs.last.to_h).to include(
      'jobtype' => 'image.resize', 'queue' => 'media', 'custom' => { 'expires_in' => 300 }
    )
  end
end

RSpec.describe Anway::Options do
  it 'lets a contract key win over a custom key with the same name' do
    wire = described_class.wire(unique_for: 60, custom: { 'unique_for' => 5, :tenant => 'a' })

    expect(wire).to eq('custom' => { 'unique_for' => 60, 'tenant' => 'a' })
  end

  it 'sends no field for a nil value' do
    expect(described_class.wire(queue: nil, track: false, custom: {})).to eq({})
  end
end

RSpec.describe 'Anway::Worker topics' do
  subscription = Anway::Worker::Subscription

  it 'makes one subscription for each topic, with the options of the class' do
    expect(RoomMessageJob.subscriptions).to eq(
      [
        subscription.new(topic: 'chat.message', queue: 'realtime', event: 'chat.broadcast', retry: 2, reserve_for: 120),
        subscription.new(topic: 'chat.edited', queue: 'realtime', event: 'chat.broadcast', retry: 2, reserve_for: 120)
      ]
    )
  end

  it 'uses the default queue without a class queue' do
    expect(PlainSubscriberJob.subscriptions).to eq(
      [subscription.new(topic: 'chat.message', queue: 'default', event: 'PlainSubscriberJob', retry: nil, reserve_for: nil)]
    )
  end

  it 'does not give the topics of a parent to a subclass' do
    expect(LateMessageJob.subscriptions).to be_empty
  end

  it 'lists the subscriptions of all registered classes' do
    expect(Anway::Worker.subscriptions).to include(*RoomMessageJob.subscriptions, *PlainSubscriberJob.subscriptions)
  end

  it 'does not send topics in a push' do
    Anway::Testing.fake!

    RoomMessageJob.perform_async('x')

    expect(Anway::Testing.jobs.last.to_h.keys).not_to include('topics')
  end
end

RSpec.describe 'Anway.publish' do
  it 'keeps events in fake mode' do
    Anway::Testing.fake!
    RoomMessageJob.received = nil

    published = Anway.publish('chat.message', [{ 'body' => 'hi' }], id: 'msg-1', custom: { source: 'web' })

    expect(published).to have_attributes(event: 'msg-1', duplicate: false)
    expect(published.jobs).to eq(Anway::Worker.subscriptions.count { |item| item.topic == 'chat.message' })
    expect(Anway::Testing.events).to eq(
      [{ 'topic' => 'chat.message', 'args' => [{ 'body' => 'hi' }], 'id' => 'msg-1', 'custom' => { 'source' => 'web' } }]
    )
    expect(RoomMessageJob.received).to be_nil

    Anway::Testing.clear

    expect(Anway::Testing.events).to be_empty
  end

  it 'runs the subscribed classes of the app in inline mode' do
    Anway::Testing.inline!
    RoomMessageJob.received = []

    published = Anway.publish('chat.edited', [{ 'body' => 'fixed' }])

    expect(published.event).to start_with('evt-')
    expect(published.jobs).to eq(1)
    expect(RoomMessageJob.received).to eq([[{ 'body' => 'fixed' }, { 'topic' => 'chat.edited', 'event' => published.event }]])
  end

  it 'rejects args that are not JSON types' do
    Anway::Testing.fake!

    expect { Anway.publish('chat.message', [{ body: 'hi' }]) }.to raise_error(ArgumentError)
    expect { Anway.publish('chat.message', 'hi') }.to raise_error(ArgumentError)
    expect(Anway::Testing.events).to be_empty
  end

  it 'publishes with the real client' do
    server = start_server

    Anway.config.url = server.url

    client = open_client(server.url)

    client.subscribe('chat.message', queue: 'realtime', event: 'chat.broadcast')

    expect(Anway.publish('chat.message', ['hi'], id: 'm1')).to eq(Anway::Client::Published.new(event: 'm1', jobs: 1, duplicate: false))
    expect(client.queue_sizes['realtime']).to eq(1)
  end
end

RSpec.describe Anway::Testing do
  it 'runs jobs at push in inline mode' do
    described_class.inline!

    NamedJob.perform_async('inline')

    expect(NamedJob.received.first).to eq('inline')
  end

  it 'runs fake jobs at drain' do
    described_class.fake!

    NamedJob.perform_async('later')
    described_class.drain

    expect(NamedJob.received.first).to eq('later')
    expect(described_class.jobs).to be_empty
  end
end

RSpec.describe Anway::Queues do
  it 'keeps a strict order without weights' do
    expect(described_class.new(%w[a b]).order).to eq(%w[a b])
  end

  it 'uses weights' do
    queues = described_class.new([['a', 9], ['b', 1]])
    first = Array.new(1000) { queues.order.first }

    expect(first.count('a')).to be > 800
    expect(queues.order).to contain_exactly('a', 'b')
  end
end

RSpec.describe Anway::Client do
  it 'opens new connections in a forked child' do
    server = start_server
    client = open_client(server.url, pool_size: 1)

    client.push(Anway::Job.new('parent'))

    pid = fork do
      # The parent holds one connection, so a new one makes two.
      connections = client.info.dig('server', 'connections')

      exit!(connections == 2 ? 0 : 1)
    end

    Process.wait(pid)

    expect(Process.last_status.exitstatus).to eq(0)
    expect(client.queue_sizes['default']).to eq(1)
  end
end
