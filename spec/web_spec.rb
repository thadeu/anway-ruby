# frozen_string_literal: true

require 'socket'
require 'stringio'

# FakeConsole records one HTTP request at a time and answers with a fixed reply.
class FakeConsole
  attr_reader :requests

  def initialize(reply)
    @reply = reply
    @requests = []
    @listener = TCPServer.new('127.0.0.1', 0)
    @thread = Thread.new { loop { serve(@listener.accept) } }
  end

  def url
    "http://127.0.0.1:#{@listener.addr[1]}"
  end

  def close
    @thread.kill
    @listener.close
  end

  private

  def serve(socket)
    line = socket.gets.to_s.chomp
    headers = {}

    while (header = socket.gets) && header != "\r\n"
      name, value = header.chomp.split(': ', 2)
      headers[name.downcase] = value
    end

    body = socket.read(headers['content-length'].to_i)

    @requests << { line: line, headers: headers, body: body }
    socket.write(@reply)
  ensure
    socket.close
  end
end

RSpec.describe Anway::Web do
  def env(method: 'GET', path: '/jobs', query: '', body: '', **headers)
    {
      'REQUEST_METHOD' => method,
      'SCRIPT_NAME' => '/anway',
      'PATH_INFO' => path,
      'QUERY_STRING' => query,
      'SERVER_NAME' => 'shop.test',
      'SERVER_PORT' => '443',
      'HTTP_HOST' => 'shop.test',
      'rack.url_scheme' => 'https',
      'rack.input' => StringIO.new(body)
    }.merge(headers)
  end

  let(:reply) { "HTTP/1.1 200 OK\r\ncontent-type: text/html\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok" }
  let(:console) { FakeConsole.new(reply) }

  after { console.close }

  it 'forwards the path, the query, the mount path, and the browser host' do
    status, headers, body = described_class.new(console.url).call(env(query: 'set=running', 'HTTP_ACCEPT' => 'text/html'))
    request = console.requests.first

    expect([status, headers['content-type'], body.join]).to eq([200, 'text/html', 'ok'])
    expect(request[:line]).to eq('GET /jobs?set=running HTTP/1.1')
    expect(request[:headers]).to include('host' => 'shop.test', 'x-forwarded-prefix' => '/anway', 'x-forwarded-proto' => 'https', 'accept' => 'text/html')
  end

  it 'keeps the session cookie and Authorization in the app' do
    described_class.new(console.url).call(env('HTTP_COOKIE' => '_shop_session=secret', 'HTTP_AUTHORIZATION' => 'Bearer secret'))

    expect(console.requests.first[:headers].keys).not_to include('cookie', 'authorization')
  end

  it 'forwards a form post with its body, type, and origin' do
    form = 'action=kill&set=working&all=1'

    described_class.new(console.url).call(
      env(method: 'POST', path: '/jobs/actions', body: form, 'CONTENT_TYPE' => 'application/x-www-form-urlencoded', 'HTTP_ORIGIN' => 'https://shop.test')
    )

    request = console.requests.first

    expect(request[:body]).to eq(form)
    expect(request[:headers]).to include('content-type' => 'application/x-www-form-urlencoded', 'origin' => 'https://shop.test')
  end

  it 'forwards a form post that Rails read before the mount' do
    form = 'action=kill&jid=a'
    read = env(method: 'POST', path: '/jobs/actions', body: form, 'CONTENT_TYPE' => 'application/x-www-form-urlencoded')

    read['rack.input'].read

    unrewindable = env(method: 'POST', path: '/jobs/actions', 'rack.request.form_vars' => form, 'CONTENT_TYPE' => 'application/x-www-form-urlencoded')

    described_class.new(console.url).call(read)
    described_class.new(console.url).call(unrewindable)

    expect(console.requests.map { |request| request[:body] }).to eq([form, form])
  end

  context 'with a redirect' do
    let(:reply) { "HTTP/1.1 303 See Other\r\nlocation: /anway/jobs?notice=1\r\ncontent-length: 0\r\nconnection: close\r\n\r\n" }

    it 'passes it to the browser without following it' do
      status, headers, = described_class.new(console.url).call(env(method: 'POST', path: '/jobs/actions'))

      expect(status).to eq(303)
      expect(headers['location']).to eq('/anway/jobs?notice=1')
    end
  end

  it 'refuses other methods' do
    status, headers, = described_class.new(console.url).call(env(method: 'DELETE'))

    expect(status).to eq(405)
    expect(headers['allow']).to eq('GET, HEAD, POST')
  end

  it 'explains how to start the console when nothing listens' do
    port = TCPServer.new('127.0.0.1', 0).then { |server| server.addr[1].tap { server.close } }
    status, _, body = described_class.new("http://127.0.0.1:#{port}").call(env)

    expect(status).to eq(502)
    expect(body.join).to include('console.path')
  end
end
