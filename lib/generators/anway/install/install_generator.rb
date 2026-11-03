# frozen_string_literal: true

require 'rails/generators'

module Anway
  module Generators
    # bin/rails generate anway:install [--active-job]
    class InstallGenerator < Rails::Generators::Base
      PUMA_LINE = 'plugin :anway'

      source_root File.expand_path('templates', __dir__)

      class_option :active_job, type: :boolean, default: false, desc: 'Use Anway as the Active Job adapter'

      def create_settings
        copy_file 'anway.yml', 'config/anway.yml'
      end

      def create_binstub
        copy_file 'anway', 'bin/anway'
        chmod 'bin/anway', 0o755
      end

      def add_puma_plugin
        path = File.join(destination_root, 'config/puma.rb')

        return unless File.exist?(path)
        return if File.read(path).include?(PUMA_LINE)

        append_to_file 'config/puma.rb', <<~RUBY

          # Runs Anway next to Puma: the embedded server and the workers. ANWAY_IN_PUMA
          # turns it on or off. Without it, it runs only in development.
          #{PUMA_LINE}
        RUBY
      end

      # The mount stays a comment: it needs a console binary, and the app must
      # choose who can open it.
      def add_console_route
        path = File.join(destination_root, 'config/routes.rb')

        return unless File.exist?(path)
        return if File.read(path).include?('Anway::Web')

        route <<~RUBY.chomp
          # The Anway console. It needs console.path in config/anway.yml. Limit it to admins:
          # authenticate :user, ->(user) { user.admin? } do
          #   mount Anway::Web => "/anway"
          # end
        RUBY
      end

      def set_active_job_adapter
        return unless options[:active_job]

        application 'config.active_job.queue_adapter = :anway'
      end

      def show_next_steps
        say <<~TEXT

          Anway is installed.

            bin/dev                 Puma starts the Anway server and workers in development
            bin/anway               the server and workers, without Puma
            bin/anway worker        only workers, for a server that runs apart

          Jobs: include Anway::Worker in a class#{options[:active_job] ? ', or use Active Job' : ', or run the generator with --active-job'}.
        TEXT
      end
    end
  end
end
