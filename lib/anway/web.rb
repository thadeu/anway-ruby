# frozen_string_literal: true

require 'net/http'
require 'uri'

module Anway
  # Web serves the Anway console inside a Rack app, such as Rails:
  #
  #   authenticate :user, ->(user) { user.admin? } do
  #     mount Anway::Web => '/anway'
  #   end
  #
  # It proxies to the console process, which bin/anway starts when
  # config/anway.yml sets console.path. The console gets the mount path in
  # X-Forwarded-Prefix, and the browser host, so its links, redirects, and
  # CSRF check work under the path. Cookies and Authorization stay in the app.
  class Web
    METHODS = %w[GET HEAD POST].freeze
    DROPPED = %w[connection keep-alive proxy-authenticate proxy-authorization te trailer transfer-encoding upgrade content-length].freeze
    PRIVATE = %w[HTTP_COOKIE HTTP_AUTHORIZATION HTTP_HOST HTTP_VERSION HTTP_CONNECTION].freeze

    def self.call(env)
      new.call(env)
    end

    def initialize(target = nil)
      @target = target
    end

    def call(env)
      return [405, { 'content-type' => 'text/plain', 'allow' => METHODS.join(', ') }, ['Method not allowed']] unless METHODS.include?(env['REQUEST_METHOD'])

      response = forward(env)
      headers = {}

      response.each_header { |name, value| headers[name] = value unless DROPPED.include?(name) }

      [response.code.to_i, headers, [response.body.to_s]]
    rescue SystemCallError, IOError, Net::OpenTimeout, Net::ReadTimeout, SocketError
      [502, { 'content-type' => 'text/html; charset=utf-8' }, [unavailable]]
    end

    private

    def target
      URI(@target || Anway.config.console_url || Settings.load.console_url)
    end

    def forward(env)
      base = target
      path = env['PATH_INFO'].to_s
      path = '/' if path.empty?
      query = env['QUERY_STRING'].to_s
      request = Net::HTTPGenericRequest.new(env['REQUEST_METHOD'], env['REQUEST_METHOD'] == 'POST', env['REQUEST_METHOD'] != 'HEAD', query.empty? ? path : "#{path}?#{query}")

      copy_headers(env, request)

      if env['REQUEST_METHOD'] == 'POST'
        request.body = body_of(env)
        request['content-type'] = env['CONTENT_TYPE'] if env['CONTENT_TYPE']
      end

      Net::HTTP.start(base.host, base.port, open_timeout: 2, read_timeout: 30) { |http| http.request(request) }
    end

    # Rails reads a form post before the mount, in Rack::MethodOverride, so
    # the input is at its end. It rewinds the input, and uses the raw form that
    # Rack keeps when the input cannot rewind.
    def body_of(env)
      input = env['rack.input']

      input.rewind if input.respond_to?(:rewind)

      body = input&.read.to_s

      body.empty? ? env['rack.request.form_vars'].to_s : body
    end

    def copy_headers(env, request)
      env.each do |key, value|
        next unless key.start_with?('HTTP_') && !PRIVATE.include?(key)

        request[key.delete_prefix('HTTP_').split('_').map(&:capitalize).join('-')] = value
      end

      request['host'] = env['HTTP_HOST'] || "#{env['SERVER_NAME']}:#{env['SERVER_PORT']}"
      request['x-forwarded-prefix'] = env['SCRIPT_NAME'].to_s
      request['x-forwarded-proto'] = env['rack.url_scheme'].to_s
      request['accept-encoding'] = 'identity'
    end

    def unavailable
      <<~HTML
        <!doctype html>
        <title>Anway console</title>
        <div style="font-family:system-ui,sans-serif;max-width:560px;margin:15vh auto;padding:0 16px;line-height:1.5">
          <h1 style="font-size:20px">The Anway console is not running</h1>
          <p>Set <code>console.path</code> in <code>config/anway.yml</code> to the console binary. Then <code>bin/anway</code>, or Puma with <code>plugin :anway</code>, starts it next to the server.</p>
          <p>To run it apart, use <code>bin/anway console</code>, and set <code>console.bind</code> to its address.</p>
        </div>
      HTML
    end
  end
end
