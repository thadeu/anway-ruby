# frozen_string_literal: true

require 'erb'
require 'optparse'
require 'yaml'

# The Railtie registers only when Rails loads before the gem.
begin
  require 'rails'
rescue LoadError
  nil
end

require 'anway'

module Anway
  # bundle exec anway -q critical,mailers:2,default -c 10
  class CLI
    EXIT_OK = 0
    EXIT_BOOT = 1
    EXIT_USAGE = 2
    DEFAULTS = { concurrency: 10, timeout: 25, labels: [] }.freeze
    DEFAULT_CONFIG = 'config/anway.yml'
    RAILS_ENTRY = 'config/environment.rb'

    def initialize(argv)
      $stdout.sync = true

      @argv = argv.dup
      @flags = {}
    end

    def run
      return EXIT_OK if parse == :done

      boot
      start
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

      raise ArgumentError, "unexpected argument: #{@argv.first}" unless @argv.empty?

      @flags[:done] ? :done : nil
    end

    def parser
      OptionParser.new do |options|
        options.banner = 'Usage: anway [options]'

        options.on('-q', '--queues LIST', 'Queues in order, as name or name:weight') do |list|
          @flags[:queues] = list.split(',').map { |entry| entry.split(':') }
        end

        options.on('-c', '--concurrency N', Integer, 'Number of job threads') { |n| @flags[:concurrency] = n }
        options.on('-t', '--timeout N', Float, 'Seconds for jobs to finish at stop') { |n| @flags[:timeout] = n }
        options.on('-r', '--require PATH', 'File that loads the jobs') { |path| @flags[:require] = path }
        options.on('-C', '--config PATH', 'YAML config file') { |path| @flags[:config] = path }
        options.on('-e', '--environment NAME', 'Environment name') { |name| @flags[:environment] = name }
        options.on('-l', '--label NAME', 'Worker label') { |name| (@flags[:labels] ||= []) << name }
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

      @options = DEFAULTS.merge(file_options(environment)).merge(@flags)

      load_app

      Anway.config.logger.level = Logger::DEBUG if @options[:verbose]

      check_database_pool
    end

    def file_options(environment)
      path = @flags[:config] || DEFAULT_CONFIG

      unless File.exist?(path)
        raise ArgumentError, "config file not found: #{path}" if @flags[:config]

        return {}
      end

      content = YAML.safe_load(ERB.new(File.read(path)).result, aliases: true) || {}
      section = content.fetch(environment, {})
      common = content.reject { |_key, value| value.is_a?(Hash) }

      common.merge(section).transform_keys(&:to_sym)
    end

    def load_app
      path = @options[:require]
      path ||= RAILS_ENTRY if File.exist?(RAILS_ENTRY)

      raise ArgumentError, 'use -r to load the jobs outside Rails' unless path

      require File.expand_path(path)

      Rails.application.eager_load! if defined?(Rails) && Rails.application
    end

    def check_database_pool
      return unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connected?

      size = ActiveRecord::Base.connection_pool.size

      return if size >= @options[:concurrency]

      Anway.config.logger.warn("database pool #{size} is smaller than concurrency #{@options[:concurrency]}")
    end

    def start
      runner = Runner.new(
        queues: queues,
        concurrency: @options[:concurrency],
        timeout: @options[:timeout],
        labels: @options[:labels]
      )

      trap_signals(runner)
      runner.run
    end

    def trap_signals(runner)
      %w[TERM INT].each { |name| Signal.trap(name) { runner.stop } }

      Signal.trap('TSTP') { runner.quiet }
      Signal.trap('TTIN') { runner.dump }
    end

    # Without a list, the worker uses the queues of its job classes.
    def queues
      return @options[:queues] if @options[:queues]

      names = Worker.classes.map { |klass| klass.job_options[:queue]&.to_s }
      names.concat(active_job_queues)

      [*names.compact, 'default'].uniq
    end

    def active_job_queues
      return [] unless defined?(ActiveJob::Base)

      ActiveJob::Base.descendants.map(&:queue_name).grep(String)
    end
  end
end
