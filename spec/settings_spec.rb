# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

RSpec.describe Anway::Settings do
  def settings(content = {}, environment: 'development', env: {})
    described_class.new(content, environment: environment, env: env)
  end

  it 'runs an embedded server on the local address by default' do
    subject = settings

    expect(subject.mode).to eq('embedded')
    expect(subject.client_url).to eq('tcp://127.0.0.1:7419')
    expect(subject.server_env).to eq('BIND_ADDR' => '127.0.0.1:7419', 'DATA_DIR' => File.expand_path('storage/anway'))
  end

  it 'uses an external server when the file has a url' do
    subject = settings({ 'production' => { 'url' => 'tcp://:p@anway.internal:7419' } }, environment: 'production')

    expect(subject.mode).to eq('external')
    expect(subject.client_url).to eq('tcp://:p@anway.internal:7419')
  end

  it 'uses an external server when ANWAY_URL is set' do
    subject = settings(env: { 'ANWAY_URL' => 'tcp://other:7419' })

    expect(subject).not_to be_embedded
    expect(subject.client_url).to eq('tcp://other:7419')
  end

  it 'lets server mode and ANWAY_SERVER choose against the url' do
    content = { 'server' => { 'mode' => 'embedded' } }

    expect(settings(content, env: { 'ANWAY_URL' => 'tcp://other:7419' })).to be_embedded
    expect(settings({}, env: { 'ANWAY_URL' => 'tcp://other:7419', 'ANWAY_SERVER' => 'embedded' })).to be_embedded
  end

  it 'merges the top keys and the server hash with the environment section' do
    content = {
      'concurrency' => 5,
      'queues' => %w[a b],
      'server' => { 'bind' => '0.0.0.0:7500' },
      'production' => { 'concurrency' => 20, 'server' => { 'password' => 'secret' } }
    }

    subject = settings(content, environment: 'production')

    expect(subject.worker_options).to eq(concurrency: 20, queues: %w[a b])
    expect(subject.client_url).to eq('tcp://:secret@127.0.0.1:7500')
    expect(subject.server_env).to include('BIND_ADDR' => '0.0.0.0:7500', 'SERVER_PASSWORD' => 'secret')
  end

  it 'opens the HTTP API for the web console only when web is set' do
    expect(settings.server_env.keys).not_to include('WEB_ADDR', 'WEB_TOKEN')

    subject = settings({ 'server' => { 'web' => '127.0.0.1:7420', 'web_token' => 'dev' } })

    expect(subject.server_env).to include('WEB_ADDR' => '127.0.0.1:7420', 'WEB_TOKEN' => 'dev')
  end

  it 'starts no console without a binary' do
    expect(settings).not_to be_console
    expect(settings.web).to be_nil
  end

  it 'opens the server API for a console next to an embedded server, with one shared token' do
    subject = settings({ 'console' => { 'path' => 'bin/console' } })

    expect(subject.console_path).to eq(File.expand_path('bin/console'))
    expect(subject.console_url).to eq('http://127.0.0.1:7421')
    expect(subject.console_env).to include('HOST' => '127.0.0.1', 'PORT' => '7421', 'ANWAY_API_URL' => 'http://127.0.0.1:7420')
    expect(subject.server_env).to include('WEB_ADDR' => '127.0.0.1:7420')
    expect(subject.console_env['WEB_TOKEN']).to eq(subject.server_env['WEB_TOKEN']).and match(/\A\h{32}\z/)
  end

  it 'uses ANWAY_CONSOLE_PATH, and the API and token that the file names' do
    content = { 'url' => 'tcp://other:7419', 'console' => { 'api' => 'http://other:7420', 'token' => 't', 'bind' => '0.0.0.0:9000' } }
    subject = settings(content, env: { 'ANWAY_CONSOLE_PATH' => '/opt/anway-console' })

    expect(subject.console_path).to eq('/opt/anway-console')
    expect(subject.console_env).to eq('HOST' => '0.0.0.0', 'PORT' => '9000', 'ANWAY_API_URL' => 'http://other:7420', 'WEB_TOKEN' => 't')
    expect(subject.console_url).to eq('http://127.0.0.1:9000')
  end

  it 'refuses a console that has no server API to read' do
    expect { settings({ 'url' => 'tcp://other:7419', 'console' => { 'path' => 'x' } }) }.to raise_error(ArgumentError, /server API/)
  end

  it 'ignores an environment section that has only comments, and keys it does not know' do
    subject = settings({ 'concurrency' => 3, 'production' => nil, 'staging' => { 'x' => 1 } }, environment: 'production')

    expect(subject.worker_options).to eq(concurrency: 3)
  end

  it 'refuses an external mode without a url, a bad mode, and a bad bind' do
    expect { settings({ 'server' => { 'mode' => 'external' } }) }.to raise_error(ArgumentError, /needs url/)
    expect { settings({ 'server' => { 'mode' => 'cloud' } }) }.to raise_error(ArgumentError, /embedded or external/)
    expect { settings({ 'server' => { 'bind' => 'localhost' } }) }.to raise_error(ArgumentError, /host:port/)
  end

  it 'loads the YAML file with ERB, and refuses a named file that does not exist' do
    path = File.expand_path('fixtures/anway.yml', __dir__)

    expect(described_class.load(path: path, environment: 'test', env: {}).worker_options).to include(concurrency: 3)
    expect { described_class.load(path: 'missing.yml', env: {}) }.to raise_error(ArgumentError, /not found/)
  end
  it 'reads the worker hostname and tag from the file, with ANWAY_HOSTNAME and ANWAY_TAG first' do
    content = { 'hostname' => 'worker.1', 'tag' => 'shop' }

    expect(settings(content).worker_options).to include(hostname: 'worker.1', tag: 'shop')
    expect(settings(content, env: { 'ANWAY_HOSTNAME' => 'web-7', 'ANWAY_TAG' => 'store' }).worker_options).to include(hostname: 'web-7', tag: 'store')
    expect(settings.worker_options).not_to include(:hostname, :tag)
  end

  it 'reads autoscale and refuses a bad one' do
    expect(settings({ 'autoscale' => { 'max' => 25 } }).worker_options[:autoscale]).to eq(max: 25)
    expect(settings({ 'autoscale' => { 'min' => 2, 'max' => 25 } }).worker_options[:autoscale]).to eq(min: 2, max: 25)
    expect(settings.worker_options).not_to include(:autoscale)
    expect { settings({ 'autoscale' => 25 }) }.to raise_error(ArgumentError, /autoscale/)
    expect { settings({ 'autoscale' => { 'min' => 30, 'max' => 25 } }) }.to raise_error(ArgumentError, /autoscale/)
  end

  it 'tells when the web token is random' do
    expect(settings({ 'server' => { 'web' => '127.0.0.1:7420' } })).to be_random_web_token
    expect(settings({ 'server' => { 'web' => '127.0.0.1:7420', 'web_token' => 'fixed' } })).not_to be_random_web_token
    expect(settings).not_to be_random_web_token
  end
end

RSpec.describe Anway::Puma::Plugin do
  it 'runs only in development unless ANWAY_IN_PUMA says otherwise' do
    expect(described_class.enabled?({})).to be(true)
    expect(described_class.enabled?('RAILS_ENV' => 'production')).to be(false)
    expect(described_class.enabled?('RAILS_ENV' => 'production', 'ANWAY_IN_PUMA' => 'true')).to be(true)
    expect(described_class.enabled?('ANWAY_IN_PUMA' => 'false')).to be(false)
    expect { described_class.enabled?('ANWAY_IN_PUMA' => 'maybe') }.to raise_error(ArgumentError)
  end

  it 'starts the app binstub when it exists, and the gem command in other cases' do
    Dir.mktmpdir do |dir|
      expect(described_class.command(dir).last).to end_with('exe/anway')

      FileUtils.mkdir_p(File.join(dir, 'bin'))
      File.write(File.join(dir, 'bin/anway'), '')

      expect(described_class.command(dir)).to eq([Gem.ruby, File.join(dir, 'bin/anway')])
    end
  end

end
