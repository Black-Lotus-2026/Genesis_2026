# frozen_string_literal: true

require_relative 'base_strategy'

module Strategies
  # Стратегия детерминированного каскада по приоритету (Priority Cascade)
  class PriorityCascadeStrategy < BaseStrategy
    def initialize(config = {})
      super('priority_cascade', config)
    end

    def select_provider(eligible_providers, _operation, _context = {})
      sorted = eligible_providers.sort_by(&:priority)
      winner = sorted.first

      reason = eligible_providers.size == 1 ? 'only_eligible_provider' : 'first_eligible'
      details = if eligible_providers.size == 1
                  "Single eligible provider among active pool (priority #{winner.priority})"
                else
                  "Selected by lowest priority rank #{winner.priority} among #{eligible_providers.size} eligible"
                end

      [winner, reason, details]
    end
  end
end
