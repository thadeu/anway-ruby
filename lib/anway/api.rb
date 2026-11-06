# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

module Anway
  # Api reads the server's HTTP API (WEB_ADDR) with its web token. It is
  # what `anway jobs` and Anway.jobs use.
  class Api
    # The server does not answer on the API address.
    class Unreachable < Error; end

    def self.from_settings(settings = Settings.load)
      url = settings.api_url

      raise Unreachable, 'no server API: set ANWAY_API_URL, or console.api in config/anway.yml' unless url

      new(url: url, token: settings.api_token)
    end

    attr_reader :url

    def initialize(url:, token: nil, timeout: 5)
      @url = url.to_s.chomp('/')
      @token = token
      @timeout = timeout
    end

    def overview = get('/api/v1/overview')

    def jobs(set:, cursor: '', limit: 50, queue: nil, jobtype: nil)
      get('/api/v1/jobs', { set: set, cursor: cursor, limit: limit, queue: queue, jobtype: jobtype }.compact)
    end

    # One job in any set, or nil when it finished or never existed.
    def job(jid)
      get("/api/v1/jobs/#{URI.encode_www_form_component(jid.to_s)}")
    rescue NotFound
      nil
    end

    # The answer was 404.
    class NotFound < Error; end

    private

    def get(path, query = {})
      uri = URI("#{@url}#{path}")
      uri.query = URI.encode_www_form(query) unless query.empty?

      request = Net::HTTP::Get.new(uri)
      request['Authorization'] = "Bearer #{@token}" if @token

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: @timeout, read_timeout: @timeout) { |http| http.request(request) }

      parse(response)
    rescue SystemCallError, IOError, SocketError, Net::OpenTimeout, Net::ReadTimeout
      raise Unreachable, "no server at #{@url} (is bin/dev running?)"
    end

    def parse(response)
      body = JSON.parse(response.body.to_s.empty? ? '{}' : response.body)

      raise NotFound, body['error'] || 'not found' if response.code == '404'
      raise Error, "the server API answered #{response.code}: #{body['error']}" unless response.code.start_with?('2')

      body
    rescue JSON::ParserError
      raise Error, "the server API answered #{response.code} without JSON"
    end
  end
end
