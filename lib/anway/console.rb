# frozen_string_literal: true

module Anway
  # Console runs the web console binary, which reads the HTTP API of the
  # server. `mount Anway::Web` serves it inside the app. console.path in
  # config/anway.yml, or ANWAY_CONSOLE_PATH, names the binary.
  class Console < Daemon
    private

    def name
      'console'
    end

    def address
      @settings.console_bind
    end

    def env
      @settings.console_env
    end

    def executable
      path = @settings.console_path

      raise Error, 'the console has no binary. Set console.path in config/anway.yml, or ANWAY_CONSOLE_PATH.' unless path
      raise Error, "the console binary is not executable: #{path}" unless File.executable?(path)

      path
    end

    def announce
      @logger.info("anway: console on #{@settings.console_url}. Mount Anway::Web in config/routes.rb to open it in the app.")
    end
  end
end
