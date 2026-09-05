# frozen_string_literal: true

require_relative 'base_strategy'
require_relative 'priority_cascade_strategy'

module Strategies
  # 1. Стратегия балансировки по числу операций (Traffic Share Balanced)
  class TrafficShareBalancedStrategy < BaseStrategy
    def initialize(config = {})
      super('traffic_share_balanced', config)
    end

    def select_provider(eligible_providers, _operation, context = {})
      total_ops = context[:total_operations].to_i

      scored = eligible_providers.map do |p|
        delta = delta_count(p, total_ops)
        [p, delta]
      end

      # Максимизируем дефицит квоты (delta_count), при равенстве - по приоритету
      winner, best_delta = scored.sort_by { |p, d| [-d, p.priority] }.first

      reason = eligible_providers.size == 1 ? 'only_eligible_provider' : 'best_score_match'
      details = "Quota deficit: delta_count=#{best_delta.round(2)}% (target=#{winner.traffic_percentage}%)"

      [winner, reason, details]
    end
  end

  # 2. Стратегия балансировки по объему оборота (Volume Share Balanced)
  class VolumeShareBalancedStrategy < BaseStrategy
    def initialize(config = {})
      super('volume_share_balanced', config)
    end

    def select_provider(eligible_providers, _operation, context = {})
      total_vol = context[:total_volume].to_f

      scored = eligible_providers.map do |p|
        delta = delta_volume(p, total_vol)
        [p, delta]
      end

      winner, best_delta = scored.sort_by { |p, d| [-d, p.priority] }.first

      reason = eligible_providers.size == 1 ? 'only_eligible_provider' : 'best_score_match'
      details = "Volume deficit: delta_vol=#{best_delta.round(2)}% (target=#{winner.traffic_percentage}%)"

      [winner, reason, details]
    end
  end

  # 3. Стратегия сегментации по суммам (Amount Tiered)
  # 500..50 000 -> payflow, 50 001..100 000 -> vipay, > 100 000 -> quickpay
  class AmountTieredStrategy < BaseStrategy
    def initialize(config = {})
      super('amount_tiered', config)
    end

    def select_provider(eligible_providers, operation, _context = {})
      amount = operation.amount

      preferred_system = if amount <= 50_000
                           'payflow'
                         elsif amount <= 100_000
                           'vipay'
                         else
                           'quickpay'
                         end

      preferred = eligible_providers.find { |p| p.payment_system == preferred_system }

      if preferred
        reason = eligible_providers.size == 1 ? 'only_eligible_provider' : 'best_score_match'
        details = "Amount tier match: #{amount.to_i} RUB routed to preferred #{preferred_system}"
        [preferred, reason, details]
      else
        # Если предпочтительный шлюз не прошел Hard-constraints, каскад по приоритету
        sorted = eligible_providers.sort_by(&:priority)
        winner = sorted.first
        reason = eligible_providers.size == 1 ? 'only_eligible_provider' : 'first_eligible'
        details = "Tier preferred #{preferred_system} not eligible, cascaded to priority #{winner.priority} (#{winner.payment_system})"
        [winner, reason, details]
      end
    end
  end

  # 4. Стратегия мультифакторного адаптивного скоринга (Hybrid Adaptive) - ОСНОВНАЯ
  class HybridAdaptiveStrategy < BaseStrategy
    def initialize(config = {})
      super('hybrid_adaptive', config)
      @bank_success_rates = config['bank_success_rates'] || {}
      @provider_success_rates = config['provider_success_rates'] || {}
      @default_success_rate = config['default_success_rate']
      @w_count = (config['w_count'] || 1.0).to_f
      @w_vol   = (config['w_vol']   || 0.8).to_f
      @w_conv  = (config['w_conv']  || 25.0).to_f
      @w_util  = (config['w_util']  || 15.0).to_f
      @w_prio  = (config['w_prio']  || 0.5).to_f

      # Штрафы арбитража
      @penalty_util_high = (config['penalty_util_high'] || 50.0).to_f
      @penalty_low_sr    = (config['penalty_low_sr']    || 50.0).to_f
    end

    def select_provider(eligible_providers, operation, context = {})
      total_ops = context[:total_operations].to_i
      total_vol = context[:total_volume].to_f
      bank = operation.bank

      scored = eligible_providers.map do |p|
        score, components = compute_score(p, bank, total_ops, total_vol)
        [p, score, components]
      end

      winner, best_score, best_components = scored.sort_by { |p, s, _| [-s, p.priority] }.first

      reason = eligible_providers.size == 1 ? 'only_eligible_provider' : 'best_score_match'
      details = "Adaptive score: #{best_score.round(2)} (#{best_components})"

      [winner, reason, details]
    end

    def bank_success_rate(provider_name, bank, fallback_rate = 0.75)
      @bank_success_rates.dig(provider_name, bank) ||
        @provider_success_rates[provider_name] || @default_success_rate || fallback_rate
    end

    private

    def compute_score(provider, bank, total_ops, total_vol)
      d_count = delta_count(provider, total_ops)
      d_vol   = delta_volume(provider, total_vol)
      sr      = bank_success_rate(provider.payment_system, bank, provider.conversion_24h)
      util    = provider.utilization_rate
      prio    = provider.priority

      # Базовый взвешенный скор:
      # Score = w_count * d_count + w_vol * d_vol + w_conv * SR - w_util * UtilRate - w_prio * Priority
      score = (@w_count * d_count) +
              (@w_vol * d_vol) +
              (@w_conv * sr) -
              (@w_util * util) -
              (@w_prio * prio)

      penalties = []

      # Level 2 Arbitration: Финансовые лимиты (утилизация > 85%)
      if util > 0.85
        score -= @penalty_util_high
        penalties << "util>85%(-#{@penalty_util_high.to_i})"
      end

      # Level 3 Arbitration: Защита от ненадежных банков (исторический SR < 30%)
      if sr < 0.30
        score -= @penalty_low_sr
        penalties << "sr<30%(-#{@penalty_low_sr.to_i})"
      end

      comp_str = "Δcnt=#{d_count.round(1)}, Δvol=#{d_vol.round(1)}, sr=#{sr.round(2)}, util=#{(util * 100).round(1)}%"
      comp_str += ", #{penalties.join(', ')}" if penalties.any?

      [score, comp_str]
    end
  end

  # Фабрика стратегий
  class StrategyFactory
    def self.create(strategy_name, config = {})
      case strategy_name.to_s.downcase
      when 'priority_cascade'
        PriorityCascadeStrategy.new(config)
      when 'traffic_share_balanced'
        TrafficShareBalancedStrategy.new(config)
      when 'volume_share_balanced'
        VolumeShareBalancedStrategy.new(config)
      when 'amount_tiered'
        AmountTieredStrategy.new(config)
      when 'hybrid_adaptive', 'scoring', 'adaptive'
        HybridAdaptiveStrategy.new(config)
      else
        # Дефолт: priority_cascade для гарантированного соответствия детерминированным тестам
        PriorityCascadeStrategy.new(config)
      end
    end
  end
end
