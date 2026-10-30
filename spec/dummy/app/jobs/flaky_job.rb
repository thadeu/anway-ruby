# frozen_string_literal: true

class FlakyJob < ApplicationJob
  class Flaky < StandardError; end

  retry_on Flaky, wait: 1, attempts: 3

  def perform(path)
    File.write(path, "#{executions}\n", mode: 'a')

    raise Flaky, 'try again' if executions < 3
  end
end
