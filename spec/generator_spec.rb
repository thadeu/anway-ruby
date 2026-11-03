# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'rbconfig'
require 'tmpdir'

RSpec.describe 'anway:install generator' do
  let(:root) { File.expand_path('..', __dir__) }
  let(:app) { Dir.mktmpdir }

  before do
    FileUtils.mkdir_p(File.join(app, 'config'))

    File.write(File.join(app, 'config/puma.rb'), "port 3000\n")
    File.write(File.join(app, 'config/routes.rb'), "Rails.application.routes.draw do\nend\n")
    File.write(File.join(app, 'config/application.rb'), <<~RUBY)
      module Shop
        class Application < Rails::Application
          config.load_defaults 8.1
        end
      end
    RUBY
  end

  after { FileUtils.rm_rf(app) }

  def generate(*args)
    script = <<~RUBY
      require 'rails/generators'
      require 'generators/anway/install/install_generator'
      Anway::Generators::InstallGenerator.start(#{args.inspect}, destination_root: #{app.inspect})
    RUBY

    output, status = Open3.capture2e(RbConfig.ruby, '-rbundler/setup', "-I#{root}/lib", '-e', script, chdir: root)

    expect(status.success?).to be(true), output

    output
  end

  def read(path)
    File.read(File.join(app, path))
  end

  it 'adds the settings, the binstub, and the Puma plugin, and leaves Active Job alone' do
    generate

    expect(read('config/anway.yml')).to include('queues: [default]').and include('<%= ENV["ANWAY_URL"] %>')
    expect(File.executable?(File.join(app, 'bin/anway'))).to be(true)
    expect(read('bin/anway')).to include("require 'anway/cli'")
    expect(read('config/puma.rb')).to include('plugin :anway')
    expect(read('config/application.rb')).not_to include('queue_adapter')
    expect(read('config/routes.rb')).to include('#   mount Anway::Web => "/anway"')
    expect(read('config/anway.yml')).to include('# console:')
  end

  it 'sets the Active Job adapter with --active-job' do
    generate('--active-job')

    expect(read('config/application.rb')).to include('config.active_job.queue_adapter = :anway')
  end

  it 'does not add the Puma plugin twice' do
    generate
    generate('--force')

    expect(read('config/puma.rb').scan('plugin :anway').size).to eq(1)
    expect(read('config/routes.rb').scan('Anway::Web').size).to eq(1)
  end

  it 'writes a settings file that Anway reads' do
    generate

    settings = Anway::Settings.load(path: File.join(app, 'config/anway.yml'), environment: 'production', env: {})

    expect(settings).to be_embedded
    expect(settings.worker_options).to eq(queues: ['default'], concurrency: 10)
    expect(Anway::Settings.load(path: File.join(app, 'config/anway.yml'), environment: 'production', env: { 'ANWAY_URL' => 'tcp://x:1' })).not_to be_embedded
  end
end
