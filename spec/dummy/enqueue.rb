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

require 'anway/testing'

Anway::Testing.fake!
WriteJob.perform_later("#{path}.fake", 'no')
puts "wrapped=#{Anway::Testing.jobs.last.custom['wrapped']}"
Anway::Testing.disable!
