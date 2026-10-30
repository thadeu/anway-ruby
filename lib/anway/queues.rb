# frozen_string_literal: true

module Anway
  # Entries are names, or [name, weight] pairs. Without weights, the order is
  # strict. With weights, each fetch uses a new random order.
  class Queues
    attr_reader :names

    def initialize(entries)
      pairs = entries.map { |entry| Array(entry) }

      @names = pairs.map { |name, _| name.to_s }.uniq
      @weighted = pairs.any? { |pair| pair.size > 1 }
      @pool = pairs.flat_map { |name, weight| [name.to_s] * Integer(weight || 1) }
    end

    def order
      @weighted ? @pool.shuffle.uniq : @names
    end
  end
end
