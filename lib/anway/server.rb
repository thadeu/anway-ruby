# frozen_string_literal: true

require 'fileutils'

module Anway
  # Server runs the anway server binary that the platform gem carries.
  # ANWAY_SERVER_PATH names another binary.
  class Server < Daemon
    BUNDLED = File.expand_path('../../libexec/anway-server', __dir__)

    def self.executable(env = ENV)
      override = env['ANWAY_SERVER_PATH'].to_s.strip

      return override unless override.empty?
      return BUNDLED if File.executable?(BUNDLED)

      raise Error, "this install of anway has no server for #{Gem::Platform.local}. " \
                   'Set ANWAY_SERVER_PATH to an anway server binary, or set url to use a server that runs apart.'
    end

    private

    def name
      'server'
    end

    def address
      @settings.bind
    end

    def env
      @settings.server_env
    end

    def executable
      self.class.executable
    end

    def prepare
      FileUtils.mkdir_p(@settings.data)

      save_web_token if @settings.random_web_token?
    end

    def save_web_token
      File.open(@settings.web_token_file, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(@settings.web_token) }
      File.chmod(0o600, @settings.web_token_file)
    end

    def announce
      @logger.info("anway: embedded server on #{@settings.bind}, data in #{@settings.data}. " \
                   'On more than one host, run one server and set ANWAY_URL.')
    end
  end
end
