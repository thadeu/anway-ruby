# frozen_string_literal: true

require 'open3'
require 'rbconfig'
require 'timeout'

RSpec.describe 'Rails integration' do
  let(:root) { File.expand_path('..', __dir__) }
  let(:dummy) { File.join(root, 'spec/dummy') }

  it 'runs ActiveJob jobs through the adapter and the worker process' do
    server = start_server
    client = open_client(server.url)
    path = File.join(server.dir, 'result')

    env = {
      'ANWAY_URL' => server.url,
      'RAILS_ENV' => 'test',
      'DUMMY_DB' => File.join(server.dir, 'dummy.sqlite3'),
      'RUBYOPT' => "-I#{root}/lib"
    }

    output, status = Open3.capture2e(env, RbConfig.ruby, 'enqueue.rb', path, chdir: dummy)

    expect(status.success?).to be(true), output
    expect(output).to include('in_transaction=1').and include('after_commit=2')
    expect(output).to include('wrapped=WriteJob')

    pid = Process.spawn(env, RbConfig.ruby, "#{root}/exe/anway", chdir: dummy, out: File::NULL, err: File::NULL)

    begin
      wait_for(15) do
        File.exist?("#{path}.plain") && File.exist?("#{path}.committed") &&
          File.exist?("#{path}.flaky") && File.read("#{path}.flaky").lines.size == 3
      end

      wait_for(15) { client.info.dig('faktory', 'tasks', 'Dead', 'size') == 1 }

      Process.kill('TERM', pid)

      status = Timeout.timeout(15) { Process.wait2(pid).last }

      expect(status.exitstatus).to eq(0)
    ensure
      begin
        Process.kill('KILL', pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end

    expect(File.exist?("#{path}.rolled_back")).to be(false)
    expect(File.read("#{path}.flaky").lines.map(&:to_i)).to eq([1, 2, 3])
    expect(retries(client)).to eq(0)
  end
end
