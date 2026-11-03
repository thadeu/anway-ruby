# frozen_string_literal: true

require 'json'
require 'net/http'

# The console shows each worker as hostname:pid with its tag, queues, and
# threads. The worker sends them in HELLO.
RSpec.describe 'worker identity' do
  after { cleanup_servers }

  def free_port
    server = TCPServer.new('127.0.0.1', 0)

    server.addr[1]
  ensure
    server.close
  end

  it 'sends the hostname, tag, queues, concurrency, autoscale, and limit in HELLO' do
    web = "127.0.0.1:#{free_port}"
    server = start_server('WEB_ADDR' => web, 'WEB_TOKEN' => 't')

    identity = { hostname: 'worker.1', tag: 'shop', queues: %w[default mailers], concurrency: 5, autoscale: { max: 12 }, max_concurrency: 10 }
    client = open_client(server.url, identity: identity)

    client.beat

    request = Net::HTTP::Get.new('/api/v1/workers', 'Authorization' => 'Bearer t')
    host, port = web.split(':')
    workers = JSON.parse(Net::HTTP.start(host, port.to_i) { |http| http.request(request) }.body)['workers']

    expect(workers.size).to eq(1)
    expect(workers.first).to include('hostname' => 'worker.1', 'pid' => Process.pid, 'tag' => 'shop',
                                     'queues' => %w[default mailers], 'concurrency' => 5)
    expect(workers.first['started_seconds']).to be_between(0, 5)
    expect(workers.first).to include('max_concurrency' => 10, 'autoscale' => { 'min' => 5, 'max' => 10 })
  end
end
