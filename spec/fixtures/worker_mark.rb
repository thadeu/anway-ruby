# frozen_string_literal: true

# Writes what the app sees of ANWAY_WORKER while the worker loads it.
File.write(ENV.fetch('WORKER_MARK'), ENV.fetch('ANWAY_WORKER', 'unset'))

require_relative 'jobs'
