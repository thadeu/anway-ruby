# frozen_string_literal: true

module Anway
  module Worker
    # One class method for each key of anway_options. Anway::Worker adds
    # them to each job class:
    #
    #   class ReceiveJob
    #     include Anway::Worker
    #
    #     event 'mail.receive'
    #     queue :default
    #     recover 16
    #
    #     def perform(mail_id); end
    #   end
    #
    # retry is a reserved word in Ruby, so its methods are recover, retries,
    # and attempts: three names for the same key. The other methods have the
    # name of the key. Each call adds one option set, with the merge rules of
    # anway_options. The DSL sets always win over the anway_options sets, in
    # any call order. Without a value, a method returns the option of the
    # class.
    module DSL
      NAMES = (Options::DECLARATION - [:retry]).to_h { |key| [key, key] }.merge(recover: :retry, retries: :retry, attempts: :retry).freeze

      # topics and cron take one or more values.
      LISTS = %i[topics cron].freeze

      NONE = Object.new.freeze

      module ClassMethods
        NAMES.each do |name, key|
          if LISTS.include?(key)
            define_method(name) do |*values|
              return anway_options[key] if values.empty?

              add_option_set({ key => values.flatten }, dsl: true)
            end
          else
            define_method(name) do |value = NONE|
              return anway_options[key] if value.equal?(NONE)

              add_option_set({ key => value }, dsl: true)
            end
          end
        end
      end
    end
  end
end
