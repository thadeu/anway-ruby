# frozen_string_literal: true

require 'anway'

class FileJob
  include Anway::Worker

  anway_options queue: 'files'

  def perform(path)
    File.write(path, 'done')
  end
end
