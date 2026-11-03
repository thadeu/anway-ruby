# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'open-uri'
require_relative 'lib/anway/version'

# Each platform gem carries the anway server for that platform. The server is
# one static Go binary, so the gnu and musl gems carry the same file.
PLATFORMS = {
  'x86_64-linux-gnu' => 'linux-amd64',
  'x86_64-linux-musl' => 'linux-amd64',
  'aarch64-linux-gnu' => 'linux-arm64',
  'aarch64-linux-musl' => 'linux-arm64',
  'x86_64-darwin' => 'darwin-amd64',
  'arm64-darwin' => 'darwin-arm64'
}.freeze

# ANWAY_SERVER_VERSION overrides the version, to test the build.
SERVER_VERSION = ENV.fetch('ANWAY_SERVER_VERSION', Anway::SERVER_VERSION)
RELEASES = "https://github.com/thadeu/anway/releases/download/v#{SERVER_VERSION}".freeze

def download(name)
  path = File.join('tmp/server', name)

  return path if File.exist?(path)

  FileUtils.mkdir_p('tmp/server')
  File.binwrite(path, URI.open("#{RELEASES}/#{name}", &:read))

  path
end

# server_binary downloads one server and checks it against checksums.txt.
def server_binary(target)
  name = "anway-v#{SERVER_VERSION}-#{target}"
  archive = download("#{name}.tar.gz")
  sums = File.read(download('checksums.txt'))
  expected = sums.lines.map(&:split).find { |_sum, file| file == "#{name}.tar.gz" }&.first

  raise "no checksum for #{name}.tar.gz" unless expected
  raise "checksum mismatch for #{name}.tar.gz" unless Digest::SHA256.file(archive).hexdigest == expected

  sh 'tar', '-xzf', archive, '-C', 'tmp/server'

  File.join('tmp/server', name, 'anway')
end

# gem_build runs outside Bundler, because Bundler would load the gemspec
# again with the platform variable and fail to resolve it.
def gem_build(output, env = {})
  run = -> { sh(env, 'gem', 'build', 'anway.gemspec', '--output', output) }

  defined?(Bundler) ? Bundler.with_unbundled_env(&run) : run.call
end

desc 'Build the gem for the ruby platform and one gem for each server platform, in pkg/'
task :gems do
  FileUtils.mkdir_p('pkg')
  FileUtils.rm_rf('libexec')

  gem_build("pkg/anway-#{Anway::VERSION}.gem")

  PLATFORMS.each do |platform, target|
    FileUtils.mkdir_p('libexec')
    FileUtils.cp(server_binary(target), 'libexec/anway-server')
    FileUtils.chmod(0o755, 'libexec/anway-server')

    gem_build("pkg/anway-#{Anway::VERSION}-#{platform}.gem", 'ANWAY_GEM_PLATFORM' => platform)
  ensure
    FileUtils.rm_rf('libexec')
  end
end
