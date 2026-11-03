# frozen_string_literal: true

require_relative 'jobs'

class SavedFileJob
  include Anway::Worker

  subscribe 'file.saved', queue: 'audit'

  def perform(path)
    File.write(path, 'audited')
  end
end
