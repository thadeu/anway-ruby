# frozen_string_literal: true

module Anway
  class Error < StandardError; end

  class NotUnique < Error
    def initialize(message = 'job not unique')
      super
    end
  end

  class Closed < Error
    def initialize(message = 'client is closed')
      super
    end
  end

  class ConnectionError < Error; end

  class UnknownJob < Error; end

  class ServerError < Error
    attr_reader :code

    def initialize(code, message)
      @code = code

      super("#{code} #{message}")
    end
  end

  # Inherits from Exception, so that `rescue => e` in a job does not catch it.
  class Shutdown < Exception; end # rubocop:disable Lint/InheritException
end
