# frozen_string_literal: true

require 'date'
require 'time'

module Analytics
  # Каждое правило возвращает параметры шаблона только при наличии фактов.
  class ReportGenerator
    TEMPLATES = {
      critical_utilization: '%{provider} исчерпал %{util}%% суточного лимита (остаток: %{rem} ₽). Рекомендация: увеличить daily_amount_limit на %{req} ₽ или снизить traffic_percentage с %{target}%% до %{suggested}%%',
      bank_monopoly: 'Перерасход квоты %{provider} (+%{drift} п.п.) вызван обработкой банков %{banks} (%{count} заявок), не поддерживаемых другими шлюзами. Рекомендация: подключить шлюзы %{other_providers} к приему данных банков',
      amount_ceiling: 'Шлюз %{provider} отстает от квоты на %{drift} п.п. из-за жесткого потолка суммы %{max_amount} ₽ (%{skipped_ops} операций отсеяно). Рекомендация: перенаправлять чеки до %{max_amount} ₽ приоритетно в %{provider}',
      reliability_risk: 'Выявлена низкая надежность %{provider} на банках %{bad_banks}. Рекомендация: ограничить in_progress_count_limit до %{safe_limit} слотов во избежание парализации очереди',
      turnover_deficit: 'Шлюз %{provider} не достигает минимального суточного оборота %{min_turnover} ₽ (факт: %{fact} ₽). Рекомендация: активировать soft-boost веса для мелких и средних чеков'
    }.freeze
    FREQUENT_SKIP_MIN_COUNT = 2
    FREQUENT_SKIP_SHARE = 0.20

    def self.generate(providers, decisions, skip_reasons_counter, **options)
      new(providers, decisions, skip_reasons_counter, **options).build_report
    end

    def initialize(providers, decisions, skip_reasons_counter, period: nil, operations: [], history_statistics: {})
      @providers = providers
      operations_by_id = operations.each_with_object({}) do |operation, index|
        raw = operation.respond_to?(:raw_data) ? operation.raw_data : operation
        index[raw['operation_id']] = raw
      end
      @decisions = decisions.map { |decision| (operations_by_id[decision['operation_id']] || {}).merge(decision) }
      @skip_reasons_counter = skip_reasons_counter
      @history_statistics = history_statistics
      @as_of = @decisions.map { |d| Time.iso8601(d['created_at']) if d['created_at'] }.compact.max
      @period = period || (@as_of ? @as_of.to_date.to_s : Date.today.to_s)
      @commercial_providers = @providers.reject(&:fallback?)
    end

    def build_report
      volumes = @providers.each_with_object({}) do |provider, result|
        selected = selected_decisions(provider)
        result[provider.payment_system] = if selected.all? { |d| d.key?('amount') }
                                            selected.sum { |d| d['amount'].to_f }
                                          else
                                            provider.processed_volume
                                          end
      end
      total_vol = volumes.values.sum
      distribution = @providers.each_with_object({}) do |provider, result|
        count = selected_decisions(provider).size
        volume = volumes[provider.payment_system]
        result[provider.payment_system] = {
          'count' => count,
          'share_pct' => percentage(count, @decisions.size),
          'target_pct' => provider.traffic_percentage,
          'volume_rub' => volume.round(2),
          'volume_share_pct' => percentage(volume, total_vol)
        }
      end

      utilization = @commercial_providers.each_with_object({}) do |provider, result|
        next unless provider.daily_amount_limit && provider.daily_amount_limit.positive?

        result[provider.payment_system] = {
          'used' => provider.daily_approved_amount.round(2),
          'limit' => provider.daily_amount_limit.round(2),
          'remaining' => [provider.daily_amount_limit - provider.daily_approved_amount, 0].max.round(2),
          'utilization_pct' => provider.utilization_pct
        }
      end
      @provider_skips = provider_skip_reasons
      @bank_outcomes = bank_outcomes
      @turnover_progress = turnover_progress

      {
        'period' => @period,
        'total_operations' => @decisions.size,
        'distribution' => distribution,
        'skip_reasons' => @skip_reasons_counter,
        'provider_skip_reasons' => @provider_skips,
        'projected_daily_utilization' => utilization,
        'daily_turnover_progress' => @turnover_progress,
        'recommendations' => build_recommendations(distribution, utilization)
      }
    end

    private

    def percentage(part, total)
      total.positive? ? (part.to_f / total * 100).round(2) : 0.0
    end

    def selected_decisions(provider)
      @decisions.select { |d| d['selected_provider'] == provider.payment_system }
    end

    def provider_skip_reasons
      result = @providers.each_with_object({}) { |p, stats| stats[p.payment_system] = Hash.new(0) }
      @decisions.each do |decision|
        Array(decision['attempts']).each do |attempt|
          next unless attempt['decision'] == 'skipped'

          result[attempt['provider']] ||= Hash.new(0)
          result[attempt['provider']][attempt['reason']] += 1
        end
      end
      result
    end

    def bank_outcomes
      result = {}
      @history_statistics.each do |provider, stats|
        result[provider] = (stats['banks'] || {}).each_with_object({}) do |(bank, values), banks|
          banks[bank] = {
            'count' => values['operation_count'].to_i,
            'failures' => values['expired_count'].to_i + values['rejected_count'].to_i
          }
        end
      end
      @decisions.each do |decision|
        observed_status = decision['status'] || decision['simulated_result']
        provider = decision['payment_system'] || decision['selected_provider']
        bank = decision['bank']
        next unless provider && bank && %w[approved expired rejected].include?(observed_status)

        result[provider] ||= {}
        result[provider][bank] ||= { 'count' => 0, 'failures' => 0 }
        result[provider][bank]['count'] += 1
        result[provider][bank]['failures'] += 1 if %w[expired rejected].include?(observed_status)
      end
      result
    end

    def turnover_progress
      return {} unless @as_of

      day_fraction = (@as_of.hour * 3600 + @as_of.min * 60 + @as_of.sec) / 86_400.0
      @commercial_providers.each_with_object({}) do |provider, result|
        next unless provider.daily_turnover_min && provider.daily_turnover_min.positive?

        result[provider.payment_system] = {
          'minimum' => provider.daily_turnover_min,
          'expected_by_now' => provider.daily_turnover_min * day_fraction,
          'actual' => provider.daily_approved_amount,
          'as_of' => @as_of.iso8601
        }
      end
    end

    def build_recommendations(distribution, utilization)
      @commercial_providers.flat_map do |provider|
        TEMPLATES.map do |rule, template|
          params = send(rule, provider, distribution[provider.payment_system], utilization[provider.payment_system])
          format(template, params.merge(provider: provider.payment_system)) if params
        end.compact
      end
    end

    def critical_utilization(provider, _distribution, utilization)
      return unless utilization && provider.utilization_rate > 0.80

      # Поднять лимит до уровня, при котором текущая утилизация составит 80%.
      required = (provider.daily_approved_amount / 0.80 - provider.daily_amount_limit).ceil
      {
        util: utilization['utilization_pct'], rem: utilization['remaining'], req: required,
        target: provider.traffic_percentage,
        suggested: (provider.traffic_percentage * 0.80 / provider.utilization_rate).round(2)
      }
    end

    def bank_monopoly(provider, distribution, _utilization)
      return unless distribution['share_pct'] > distribution['target_pct'] + 10

      others = @commercial_providers.reject { |p| p == provider }.select { |p| p.active? && p.traffic_percentage.positive? }
      return if others.empty?

      monopolized = selected_decisions(provider).select do |decision|
        bank = decision['bank']
        bank && provider.supports_bank?(bank) && others.none? { |other| other.supports_bank?(bank) }
      end
      return if monopolized.empty?

      { drift: (distribution['share_pct'] - distribution['target_pct']).round(2),
        banks: monopolized.map { |d| d['bank'] }.uniq.sort.join(', '), count: monopolized.size,
        other_providers: others.map(&:payment_system).sort.join(', ') }
    end

    def amount_ceiling(provider, distribution, _utilization)
      return unless provider.limit_amount_max && distribution['share_pct'] < distribution['target_pct'] - 10

      skipped = @provider_skips[provider.payment_system]['amount_exceeds_limit']
      return unless skipped >= FREQUENT_SKIP_MIN_COUNT && skipped.to_f / @decisions.size >= FREQUENT_SKIP_SHARE

      { drift: (distribution['target_pct'] - distribution['share_pct']).round(2),
        max_amount: provider.limit_amount_max, skipped_ops: skipped }
    end

    def reliability_risk(provider, _distribution, _utilization)
      bad_banks = (@bank_outcomes[provider.payment_system] || {}).select { |_bank, stats| stats['failures'].positive? }
      return if bad_banks.empty?

      failure_rate = bad_banks.values.sum { |stats| stats['failures'] }.to_f / bad_banks.values.sum { |stats| stats['count'] }
      slots = provider.in_progress_count_limit || [provider.in_progress_count, 1].max
      return unless slots.positive?

      { bad_banks: bad_banks.keys.sort.join(', '), safe_limit: [(slots * (1 - failure_rate)).floor, 1].max }
    end

    def turnover_deficit(provider, _distribution, _utilization)
      progress = @turnover_progress[provider.payment_system]
      return unless progress && progress['actual'] < progress['expected_by_now']

      { min_turnover: progress['minimum'], fact: progress['actual'] }
    end
  end
end
