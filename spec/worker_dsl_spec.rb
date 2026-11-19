# frozen_string_literal: true

class DslJob
  include Anway::Worker

  event 'dsl.receive'
  queue :default
  recover 16
  topics 'dsl.a', 'dsl.b'

  def perform(_id); end
end

class DslFirstJob
  include Anway::Worker

  queue 'dsl'
  recover 3

  anway_options event: 'dsl.first', queue: 'options', retry: 9, reserve_for: 60

  def perform; end
end

class DslLastJob
  include Anway::Worker

  anway_options event: 'dsl.options', queue: 'options', retry: 9

  event 'dsl.last'
  queue 'dsl'

  def perform; end
end

RSpec.describe Anway::Worker::DSL do
  it 'declares the options with one method for each key' do
    options = DslJob.anway_options

    expect(options).to include(event: 'dsl.receive', queue: :default, retry: 16, topics: %w[dsl.a dsl.b])
  end

  it 'returns the option without a value' do
    expect([DslJob.event, DslJob.queue, DslJob.recover, DslJob.topics]).to eq(['dsl.receive', :default, 16, %w[dsl.a dsl.b]])
  end

  it 'has recover, retries, and attempts for retry' do
    job = Class.new do
      include Anway::Worker
    
      recover 1
      retries 2
    end

    expect([job.recover, job.retries, job.attempts]).to eq([2, 2, 2])

    job.attempts 3

    expect(job.anway_options[:retry]).to eq(3)
  end

  it 'wins over anway_options that come after it' do
    expect(DslFirstJob.anway_options).to include(event: 'dsl.first', queue: 'dsl', retry: 3, reserve_for: 60)
  end

  it 'wins over anway_options that come before it' do
    expect(DslLastJob.anway_options).to include(event: 'dsl.last', queue: 'dsl', retry: 9)
  end

  it 'registers the event of the DSL' do
    expect(Anway::Worker.find('dsl.last')).to eq(DslLastJob)
    expect { Anway::Worker.find('dsl.options') }.to raise_error(Anway::UnknownJob)
  end

  it 'refuses a bad value when the class loads' do
    expect do
      Class.new do
        include Anway::Worker
      
        on_dead({ queue: 'x' })
      end
    end.to raise_error(ArgumentError)
  end
end
