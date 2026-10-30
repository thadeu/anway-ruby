# frozen_string_literal: true

class DoomedJob < ApplicationJob
  class Doomed < StandardError; end

  retry_on Doomed, wait: 1, attempts: 2

  def perform
    raise Doomed, 'always'
  end
end
