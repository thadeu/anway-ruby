# frozen_string_literal: true

require 'logger'
require 'anway'
require 'anway/testing'
require_relative 'support/server'

Anway.config.logger = Logger.new(File::NULL)

RSpec.configure do |config|
  config.include ServerHelpers

  config.before do
    Anway.config.middleware.clear
    Anway.config.error_handlers.clear
    Anway::Testing.disable!
    Anway::Testing.clear
  end

  config.after do
    cleanup_servers
    Anway.reset!
    Anway.config.url = nil
  end
end
