# frozen_string_literal: true

require_relative 'lib/anway/version'

Gem::Specification.new do |spec|
  spec.name = 'anway'
  spec.version = Anway::VERSION
  spec.authors = ['Thadeu']
  spec.summary = 'Ruby and Rails client and worker for the Anway job server'
  spec.homepage = 'https://github.com/thadeu/anway-ruby'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.4'

  spec.files = Dir['lib/**/*', 'exe/*', 'LICENSE', 'README.md']
  spec.bindir = 'exe'
  spec.executables = ['anway']

  spec.add_dependency 'logger', '~> 1.6'
end
