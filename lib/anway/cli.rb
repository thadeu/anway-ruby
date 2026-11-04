# frozen_string_literal: true

require 'optparse'

# The Railtie registers only when Rails loads before the gem.
begin
  require 'rails'
rescue LoadError
  nil
end

require 'anway'

module Anway
  # bundle exec anway                  the embedded server when config/anway.yml has no url, the
  #                                    console when it sets console.path, and workers
  # bundle exec anway server           only the server
  # bundle exec anway console          only the console
  # bundle exec anway worker -q mail   only workers
  class CLI
    EXIT_OK = 0
    EXIT_BOOT = 1
    EXIT_USAGE = 2
    DEFAULTS = { concurrency: 10, timeout: 25, labels: [] }.freeze
    COMMANDS = %w[server console worker].freeze
    RAILS_ENTRY = 'config/environment.rb'

    def initialize(argv)
      $stdout.sync = true

      @argv = argv.dup
      @flags = {}
    end

    def run
      return EXIT_OK if parse == :done

      boot

      return Server.new(@settings).exec if @command == 'server'
      return Console.new(@settings).exec if @command == 'console'

      # The app can tell that it runs in a worker process, for example to turn
      # off code reloading.
      ENV['ANWAY_WORKER'] = '1'

      load_app
      run_workers
      EXIT_OK
    rescue OptionParser::ParseError, ArgumentError => e
      warn("anway: #{e.message}")

      EXIT_USAGE
    rescue Error, ScriptError, StandardError => e
      warn("anway: #{e.class}: #{e.message}")

      EXIT_BOOT
    end

    private

    def parse
      parser.parse!(@argv)

      @command = @argv.shift if COMMANDS.include?(@argv.first)

      raise ArgumentError, "unexpected argument: #{@argv.first}" unless @argv.empty?

      @flags[:done] ? :done : nil
    end

    def parser
      OptionParser.new do |options|
        options.banner = 'Usage: anway [server|console|worker] [options]'

        options.on('-q', '--queues LIST', 'Queues in order, as name or name:weight') do |list|
          @flags[:queues] = list.split(',').map { |entry| entry.split(':') }
        end

        options.on('-c', '--concurrency N', Integer, 'Number of job threads') { |n| @flags[:concurrency] = n }
        options.on('-t', '--timeout N', Float, 'Seconds for jobs to finish at stop') { |n| @flags[:timeout] = n }
        options.on('-r', '--require PATH', 'File that loads the jobs') { |path| @flags[:require] = path }
        options.on('-C', '--config PATH', 'YAML config file') { |path| @flags[:config] = path }
        options.on('-e', '--environment NAME', 'Environment name') { |name| @flags[:environment] = name }
        options.on('-l', '--label NAME', 'Worker label') { |name| (@flags[:labels] ||= []) << name }
        options.on('-g', '--tag NAME', 'Name of the app in the console') { |name| @flags[:tag] = name }
        options.on('-a', '--autoscale MAX', Integer, 'Turn on autoscale, up to MAX threads') { |n| @flags[:autoscale] = { max: n } }
        options.on('-v', '--verbose', 'Debug logs') { @flags[:verbose] = true }

        options.on('-V', '--version', 'Print the version') do
          puts "anway #{VERSION}"

          @flags[:done] = true
        end

        options.on('-h', '--help', 'Print this help') do
          puts options

          @flags[:done] = true
        end
      end
    end

    def boot
      environment = @flags[:environment] || ENV['RAILS_ENV'] || ENV['APP_ENV'] || 'development'

      ENV['RAILS_ENV'] ||= environment
      ENV['APP_ENV'] ||= environment

      @settings = Settings.load(path: @flags[:config], environment: environment)
      @options = DEFAULTS.merge(@settings.worker_options).merge(@flags)

      Anway.config.logger.level = Logger::DEBUG if @options[:verbose]
    end

    # The app loads first, so that a usage error never leaves a server running.
    # The console stops first, and the server last, so jobs can still report.
    def run_workers
      server = Server.new(@settings) if @command.nil? && @settings.embedded?
      console = Console.new(@settings) if @command.nil? && @settings.console?

      begin
        server&.start
        console&.start

        start
      ensure
        console&.stop
        server&.stop
      end
    end

    def load_app
      path = @options[:require]
      path ||= RAILS_ENTRY if File.exist?(RAILS_ENTRY)

      raise ArgumentError, 'use -r to load the jobs outside Rails' unless path

      require File.expand_path(path)

      Rails.application.eager_load! if defined?(Rails) && Rails.application

      check_database_pool
    end

    # Each job thread can hold a database connection, so the pool size is the
    # most threads that the worker runs. Rails connects at the first query, but
    # the pool exists after boot.
    def database_pool
      return nil unless defined?(ActiveRecord::Base)

      ActiveRecord::Base.connection_pool.size
    rescue StandardError
      nil
    end

    def check_database_pool
      size = database_pool

      return unless size

      logger = Anway.config.logger
      max = @options.dig(:autoscale, :max)

      logger.warn("database pool #{size} is smaller than concurrency #{@options[:concurrency]}") if size < @options[:concurrency]
      logger.warn("autoscale max #{max} is above the database pool #{size}, so the worker runs at most #{size} threads. Raise pool in config/database.yml.") if max && max > size
    end

    def start
      runner = Runner.new(
        url: Anway.config.url || @settings.client_url,
        queues: queues,
        concurrency: @options[:concurrency],
        timeout: @options[:timeout],
        labels: @options[:labels],
        hostname: @options[:hostname],
        tag: @options[:tag] || default_tag,
        autoscale: @options[:autoscale],
        limit: database_pool
      )

      trap_signals(runner)
      runner.run
    end

    # The app folder, as Sidekiq does. A Capistrano release folder has a
    # number as its name, so the folder above it names the app.
    def default_tag
      root = defined?(Rails) && Rails.respond_to?(:root) && Rails.root ? Rails.root.to_s : Dir.pwd
      name = File.basename(root)

      name.match?(/\A\d+\z/) ? File.basename(File.dirname(File.dirname(root))) : name
    end

    def trap_signals(runner)
      %w[TERM INT].each { |name| Signal.trap(name) { runner.stop } }

      Signal.trap('TSTP') { runner.quiet }
      Signal.trap('TTIN') { runner.dump }
    end

    # Without a list, the worker uses the queues of its job classes and of
    # their subscriptions. With a list, the runner logs a warning for each
    # subscription queue that is not in it.
    def queues
      return @options[:queues] if @options[:queues]

      names = Worker.classes.map { |klass| klass.anway_options[:queue]&.to_s }
      names.concat(Worker.subscriptions.map(&:queue))
      names.concat(active_job_queues)

      [*names.compact, 'default'].uniq
    end

    def active_job_queues
      return [] unless defined?(ActiveJob::Base)

      ActiveJob::Base.descendants.map(&:queue_name).grep(String)
    end
  end
end
