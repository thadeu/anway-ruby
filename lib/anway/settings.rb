# frozen_string_literal: true

require 'erb'
require 'securerandom'
require 'yaml'

module Anway
  # Settings reads config/anway.yml. The keys at the top apply to every
  # environment, and the section of the current environment overrides them.
  #
  #   queues: [critical, default]
  #   concurrency: 10
  #
  #   production:
  #     url: <%= ENV["ANWAY_URL"] %>
  #
  # The server is embedded, so the app runs it, unless a url is set in the
  # file or in ANWAY_URL. `server: { mode: }` or ANWAY_SERVER can still choose.
  class Settings
    DEFAULT_PATH = 'config/anway.yml'
    DEFAULT_BIND = '127.0.0.1:7419'
    DEFAULT_DATA = 'storage/anway'
    DEFAULT_WEB = '127.0.0.1:7420'
    DEFAULT_CONSOLE = '127.0.0.1:7421'
    MODES = %w[embedded external].freeze
    KEYS = %w[queues concurrency timeout labels hostname tag autoscale require url server console].freeze
    SERVER_KEYS = %w[mode bind data password web web_token].freeze
    CONSOLE_KEYS = %w[path bind api token].freeze

    def self.environment(env = ENV)
      env['RAILS_ENV'] || env['APP_ENV'] || env['RACK_ENV'] || 'development'
    end

    # A missing file is fine, unless the caller named it.
    def self.load(path: nil, environment: nil, env: ENV)
      file = path || DEFAULT_PATH

      raise ArgumentError, "config file not found: #{file}" if path && !File.exist?(file)

      content = File.exist?(file) ? YAML.safe_load(ERB.new(File.read(file)).result, aliases: true) : {}

      new(content || {}, environment: environment || self.environment(env), env: env)
    end

    def initialize(content, environment:, env: ENV)
      section = content[environment].is_a?(Hash) ? content[environment] : {}

      @values = content.slice(*KEYS).merge(section.slice(*KEYS))
      @server = section_of(content, 'server', SERVER_KEYS).merge(section_of(section, 'server', SERVER_KEYS))
      @console = section_of(content, 'console', CONSOLE_KEYS).merge(section_of(section, 'console', CONSOLE_KEYS))
      @env = env

      check!
    end

    # Options for the worker, as the CLI names them.
    # ANWAY_HOSTNAME and ANWAY_TAG come before the file.
    def worker_options
      options = @values.slice('queues', 'concurrency', 'timeout', 'labels', 'hostname', 'tag', 'require').transform_keys(&:to_sym)

      options[:hostname] = present(@env['ANWAY_HOSTNAME']) || present(options[:hostname])
      options[:tag] = present(@env['ANWAY_TAG']) || present(options[:tag])
      options[:autoscale] = autoscale

      options.compact
    end

    # autoscale: { max: n } or { min: n, max: n }, or nil when it is off.
    def autoscale
      value = @values['autoscale']

      return nil unless value.is_a?(Hash)

      value.slice('min', 'max').transform_keys(&:to_sym)
    end

    # The url of a server that runs apart: from the file, then from ANWAY_URL.
    def url
      present(@values['url']) || present(@env['ANWAY_URL'])
    end

    def mode
      present(@env['ANWAY_SERVER']) || present(@server['mode']) || (url ? 'external' : 'embedded')
    end

    def embedded?
      mode == 'embedded'
    end

    def bind
      present(@server['bind']) || DEFAULT_BIND
    end

    def data
      present(@server['data']) || DEFAULT_DATA
    end

    def password
      present(@server['password'])
    end

    # The url that clients in this app use: the external server, or the
    # embedded one on its local address.
    def client_url
      return url unless embedded?

      host, port = split_bind
      auth = password ? ":#{password}@" : ''

      "tcp://#{auth}#{Daemon.local_host(host)}:#{port}"
    end

    # The address of the HTTP API that the web console reads. It is off
    # unless it is set, or the console runs next to an embedded server.
    def web
      present(@server['web']) || (console? && embedded? ? DEFAULT_WEB : nil)
    end

    # Without a token in the file, the server and the console that this
    # process starts share a random one.
    def web_token
      present(@server['web_token']) || (web ? (@random_token ||= SecureRandom.hex(16)) : nil)
    end

    # A random token changes at each start, so a server or console from an
    # earlier start does not accept it.
    def random_web_token?
      !web.nil? && present(@server['web_token']).nil?
    end

    # The web console binary: ANWAY_CONSOLE_PATH, then console.path.
    def console_path
      path = present(@env['ANWAY_CONSOLE_PATH']) || present(@console['path'])

      path && File.expand_path(path)
    end

    def console?
      !console_path.nil?
    end

    def console_bind
      present(@console['bind']) || DEFAULT_CONSOLE
    end

    # The address where `mount Anway::Web` finds the console.
    def console_url
      host, port = split(console_bind)

      "http://#{Daemon.local_host(host)}:#{port}"
    end

    # The HTTP API that the console reads: console.api, or the API of the
    # embedded server.
    def console_api
      return present(@console['api']) if present(@console['api'])
      return nil unless web

      host, port = split(web)

      "http://#{Daemon.local_host(host)}:#{port}"
    end

    def console_env
      host, port = split(console_bind)

      { 'HOST' => host, 'PORT' => port, 'ANWAY_API_URL' => console_api, 'WEB_TOKEN' => present(@console['token']) || web_token.to_s }
    end

    # The environment of the server binary.
    def server_env
      env = { 'BIND_ADDR' => bind, 'DATA_DIR' => File.expand_path(data) }

      env['SERVER_PASSWORD'] = password if password
      env['WEB_ADDR'] = web if web
      env['WEB_TOKEN'] = web_token if web_token

      env
    end

    private

    def section_of(hash, name, keys)
      value = hash[name]

      return {} if value.nil?

      raise ArgumentError, "#{name} must be a hash of #{keys.join(', ')}" unless value.is_a?(Hash)

      value.slice(*keys)
    end

    def check!
      check_autoscale!
      raise ArgumentError, "server mode must be embedded or external, not #{mode}" unless MODES.include?(mode)
      raise ArgumentError, 'an external server needs url or ANWAY_URL' if mode == 'external' && url.nil?
      raise ArgumentError, "server bind must be host:port, not #{bind}" unless split_bind.last.to_s.match?(/\A\d+\z/)
      raise ArgumentError, "console bind must be host:port, not #{console_bind}" unless split(console_bind).last.to_s.match?(/\A\d+\z/)
      raise ArgumentError, 'the console needs a server API: set server.web, or console.api' if console? && console_api.nil?
    end

    def check_autoscale!
      value = @values['autoscale']

      return if value.nil?

      message = 'autoscale must be a hash with max, and min if you want, as positive numbers'

      raise ArgumentError, message unless value.is_a?(Hash) && value['max'].is_a?(Integer) && value['max'].positive?
      raise ArgumentError, message unless value['min'].nil? || (value['min'].is_a?(Integer) && value['min'].between?(1, value['max']))
    end

    def split_bind
      split(bind)
    end

    def split(address)
      host, _, port = address.rpartition(':')

      [host, port]
    end

    def present(value)
      text = value.to_s.strip

      text.empty? ? nil : text
    end
  end
end
