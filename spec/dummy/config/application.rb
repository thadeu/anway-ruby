# frozen_string_literal: true

require 'rails'
require 'active_record/railtie'
require 'active_job/railtie'
require 'anway'

class DummyApplication < Rails::Application
  config.root = File.expand_path('..', __dir__)
  config.eager_load = true
  config.secret_key_base = 'test'
  config.logger = Logger.new($stdout)
  config.active_job.queue_adapter = :anway
end
