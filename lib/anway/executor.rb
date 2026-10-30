# frozen_string_literal: true

module Anway
  # Runs one job through the reloader and the middleware.
  module Executor
    module_function

    def call(job)
      Anway.config.reloader.call do
        klass = Worker.find(job.type)

        chain(job) do
          instance = klass.new

          instance.job = job
          instance.perform(*job.args)
        end
      end
    end

    def chain(job, &block)
      runner = Anway.config.middleware.reverse.reduce(block) do |nextone, middleware|
        -> { middleware.call(job) { nextone.call } }
      end

      runner.call
    end
  end
end
