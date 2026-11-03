# frozen_string_literal: true

module Anway
  module Puma
    # Plugin holds the logic of `plugin :anway`, so that it can be tested
    # without Puma. lib/puma/plugin/anway.rb connects it to Puma.
    module Plugin
      ON = %w[1 true yes on].freeze
      OFF = %w[0 false no off].freeze

      # ANWAY_IN_PUMA turns the plugin on or off. Without it, the plugin runs
      # only in development, as SOLID_QUEUE_IN_PUMA does for Solid Queue.
      def self.enabled?(env = ENV)
        value = env['ANWAY_IN_PUMA'].to_s.strip.downcase

        return Settings.environment(env) == 'development' if value.empty?
        return true if ON.include?(value)
        return false if OFF.include?(value)

        raise ArgumentError, "ANWAY_IN_PUMA must be true or false, not #{env['ANWAY_IN_PUMA']}"
      end

      # The app binstub loads Bundler and the app. Without it, the gem command
      # runs with Bundler.
      def self.command(root = Dir.pwd)
        binstub = File.join(root, 'bin/anway')

        return [Gem.ruby, binstub] if File.exist?(binstub)

        [Gem.ruby, '-rbundler/setup', File.expand_path('../../../exe/anway', __dir__)]
      end
    end
  end
end
