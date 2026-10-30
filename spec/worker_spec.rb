# frozen_string_literal: true

class NamedJob
  include Anway::Worker

  job_type 'email.send'
  job_options queue: 'mailers', retry: 5, custom: { unique_for: 60 }

  class << self
    attr_accessor :received
  end

  def perform(address)
    self.class.received = [address, jid]
  end
end

class ChildJob < NamedJob
  job_type 'child.job'
  job_options retry: 1
end

RSpec.describe Anway::Worker do
  before { Anway::Testing.fake! }

  it 'builds the job from the class options' do
    NamedJob.perform_async('a@b.com')

    job = Anway::Testing.jobs.first

    expect(job.type).to eq('email.send')
    expect(job.queue).to eq('mailers')
    expect(job.retry).to eq(5)
    expect(job.args).to eq(['a@b.com'])
    expect(job.custom).to eq('unique_for' => 60)
  end

  it 'finds the class by job type only when it is registered' do
    expect(described_class.find('email.send')).to eq(NamedJob)
    expect(described_class.find('child.job')).to eq(ChildJob)
    expect { described_class.find('NamedJob') }.to raise_error(Anway::UnknownJob)
    expect { described_class.find('Kernel') }.to raise_error(Anway::UnknownJob)
  end

  it 'inherits options' do
    expect(ChildJob.job_options).to include(queue: 'mailers', retry: 1)
  end

  it 'schedules jobs' do
    NamedJob.perform_in(60, 'x')

    expect(Time.parse(Anway::Testing.jobs.last.at)).to be_within(5).of(Time.now + 60)
  end

  it 'changes options for one push' do
    NamedJob.set(queue: 'low').perform_async('x')

    expect(Anway::Testing.jobs.last.queue).to eq('low')
  end

  it 'rejects args that are not JSON types' do
    expect { NamedJob.perform_async(:symbol) }.to raise_error(ArgumentError)
    expect { NamedJob.perform_async(Time.now) }.to raise_error(ArgumentError)
    expect { NamedJob.perform_async(key: 1) }.to raise_error(ArgumentError)
  end

  it 'pushes a job with no local class' do
    Anway.push('image.resize', [42], queue: 'media')

    expect(Anway::Testing.jobs.last.to_h).to include('jobtype' => 'image.resize', 'queue' => 'media')
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
