# frozen_string_literal: true

require 'logger'

module Anway
  class Configuration
    attr_accessor :url, :console_url, :pool_size, :timeout, :tls, :logger, :push_wrapper, :reloader, :log_tags
    attr_reader :middleware, :error_handlers

    def initialize
      @url = nil
      @console_url = nil
      @pool_size = 8
      @timeout = 10
      @tls = nil
      @log_tags = true
      @logger = Logger.new($stdout, level: Logger::INFO)
      @push_wrapper = ->(&block) { block.call }
      @reloader = ->(&block) { block.call }
      @middleware = []
      @error_handlers = []
    end

    # The first middleware added is the outermost. An object has `call(job)`
    # and yields to run the next one.
    def use(middleware)
      @middleware << middleware
    end

    def on_error(&block)
      @error_handlers << block
    end
  end
end
