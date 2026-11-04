# frozen_string_literal: true

require_relative 'config/environment'

ActiveRecord::Base.connection.execute('CREATE TABLE IF NOT EXISTS items (id INTEGER PRIMARY KEY)')

path = ARGV.fetch(0)

WriteJob.perform_later("#{path}.plain", 'ok')
FlakyJob.perform_later("#{path}.flaky")
DoomedJob.perform_later

ActiveRecord::Base.transaction do
  WriteJob.perform_later("#{path}.rolled_back", 'no')

  raise ActiveRecord::Rollback
end

ActiveRecord::Base.transaction do
  WriteJob.perform_later("#{path}.committed", 'yes')

  puts "in_transaction=#{Anway.client.queue_sizes['mailers']}"
end

puts "after_commit=#{Anway.client.queue_sizes['mailers']}"

# Counts the calls, to show that perform_all_later sends one PUSHB and no PUSH.
module CountCalls
  class << self
    attr_accessor :push, :push_bulk
  end

  self.push = 0
  self.push_bulk = 0

  def push(...)
    CountCalls.push += 1

    super
  end

  def push_bulk(...)
    CountCalls.push_bulk += 1

    super
  end
end

Anway::Client.prepend(CountCalls)

bulk = [
  WriteJob.new("#{path}.bulk_one", 'one'),
  WriteJob.new("#{path}.bulk_two", 'two'),
  WriteJob.new("#{path}.bulk_later", 'later').set(wait: 2)
]

enqueued_count = nil

ActiveSupport::Notifications.subscribe('enqueue_all.active_job') { |event| enqueued_count = event.payload[:enqueued_count] }

ActiveJob.perform_all_later(bulk)

sizes = Anway.client.queue_sizes
scheduled = Anway.client.info.dig('faktory', 'tasks', 'Scheduled', 'size')

puts "bulk_calls=#{CountCalls.push_bulk} push_calls=#{CountCalls.push}"
puts "bulk_enqueued=#{bulk.count(&:successfully_enqueued?)} bulk_count=#{enqueued_count} bulk_ids=#{bulk.count(&:provider_job_id)}"
puts "bulk_mailers=#{sizes['mailers']} bulk_scheduled=#{scheduled}"

# Gives the second job the jid of a job that exists, so the server refuses it.
module DuplicateSecond
  class << self
    attr_accessor :jid
  end

  def push_bulk(jobs)
    jobs[1].jid = DuplicateSecond.jid if DuplicateSecond.jid && jobs.size > 1

    super
  end
end

Anway::Client.prepend(DuplicateSecond)

DuplicateSecond.jid = Anway.client.push(Anway::Job.new('refused.holder', [], queue: 'holders'))

refused = [WriteJob.new("#{path}.refused_one", 'one'), WriteJob.new("#{path}.refused_two", 'two')]

ActiveJob.perform_all_later(refused)

DuplicateSecond.jid = nil

puts "refused_enqueued=#{refused.map(&:successfully_enqueued?).join(',')} refused_count=#{enqueued_count}"
puts "refused_error=#{refused.last.enqueue_error.class}"

require 'anway/testing'

Anway::Testing.fake!
WriteJob.perform_later("#{path}.fake", 'no')
puts "wrapped=#{Anway::Testing.jobs.last.custom['wrapped']}"
Anway::Testing.disable!
