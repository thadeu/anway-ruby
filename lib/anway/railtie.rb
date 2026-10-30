# frozen_string_literal: true

module Anway
  class Railtie < Rails::Railtie
    # Rails looks up the adapter in active_job.set_configs.
    initializer 'anway.active_job', before: 'active_job.set_configs' do
      require 'active_job/queue_adapters/anway_adapter' if defined?(ActiveJob)
    end

    initializer 'anway.transactions' do
      ActiveSupport.on_load(:active_record) do
        Anway.config.push_wrapper = ->(&block) { ActiveRecord.after_all_transactions_commit(&block) }
      end
    end

    config.after_initialize do |app|
      Anway.config.logger = Rails.logger if Rails.logger
      Anway.config.reloader = ->(&block) { app.reloader.wrap(&block) }

      Anway.config.on_error { |error, _job| Rails.error.report(error, handled: true, source: 'anway') }
    end
  end
end
