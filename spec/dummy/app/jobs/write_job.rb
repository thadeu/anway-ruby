# frozen_string_literal: true

class WriteJob < ApplicationJob
  queue_as :mailers

  def perform(path, content)
    File.write(path, content)
  end
end
