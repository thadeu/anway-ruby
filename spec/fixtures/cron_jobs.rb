# frozen_string_literal: true

require 'anway'

class DailyReportJob
  include Anway::Worker

  anway_options queue: 'reports', cron: '0 6 * * *'

  def perform; end
end
