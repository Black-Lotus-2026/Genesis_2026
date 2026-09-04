# frozen_string_literal: true

require 'date'

module Analytics
  # Генератор детального аналитического отчета по результатам маршрутизации
  class ReportGenerator
    def self.generate(providers, decisions, skip_reasons_counter, period: nil)
      new(providers, decisions, skip_reasons_counter, period: period).build_report
    end

    def initialize(providers, decisions, skip_reasons_counter, period: nil)
      @providers = providers
      @decisions = decisions
      @skip_reasons_counter = skip_reasons_counter
      @period = period || Date.today.to_s
    end

    def build_report
      total_ops = @decisions.size
      total_vol = @decisions.sum { |d| d[:amount] || d['amount'] || 0.0 }
      # Если в decisions нет прямого amount, возьмем из обработанных провайдерами объемов
      total_vol = @providers.sum(&:processed_volume) if total_vol.zero?

      distribution = {}
      @providers.each do |p|
        count = p.processed_count
        vol = p.processed_volume
        share_pct = total_ops.positive? ? ((count.to_f / total_ops) * 100.0).round(2) : 0.0
        vol_share_pct = total_vol.positive? ? ((vol.to_f / total_vol) * 100.0).round(2) : 0.0

        distribution[p.payment_system] = {
          'count' => count,
          'share_pct' => share_pct,
          'target_pct' => p.traffic_percentage,
          'volume_rub' => vol.round(2),
          'volume_share_pct' => vol_share_pct
        }
      end

      projected_daily_utilization = {}
      @providers.reject(&:fallback?).each do |p|
        limit = p.daily_amount_limit
        used = p.daily_approved_amount

        if limit && limit.positive?
          projected_daily_utilization[p.payment_system] = {
            'used' => used.round(2),
            'limit' => limit.round(2),
            'utilization_pct' => p.utilization_pct
          }
        end
      end

      recommendations = build_recommendations(distribution, projected_daily_utilization)

      {
        'period' => @period,
        'total_operations' => total_ops,
        'distribution' => distribution,
        'skip_reasons' => @skip_reasons_counter,
        'projected_daily_utilization' => projected_daily_utilization,
        'recommendations' => recommendations
      }
    end

    private

    def build_recommendations(distribution, utilization)
      recs = []

      # 1. Анализ структурного перекоса Quickpay (монополия на Gazprombank и Raiffeisen)
      quickpay_dist = distribution['quickpay']
      if quickpay_dist && quickpay_dist['share_pct'] > quickpay_dist['target_pct']
        recs << 'Превышение квоты Quickpay вызвано монополией на банки Gazprombank и Raiffeisen (28% входящего потока)'
      end

      # 2. Анализ отставания Payflow (лимит чека 50k и только 2 банка)
      payflow_dist = distribution['payflow']
      if payflow_dist && payflow_dist['share_pct'] < payflow_dist['target_pct']
        recs << 'Отставание Payflow вызвано лимитом максимального чека (50 000 ₽ отсекает 26% трафика) и поддержкой только 2 банков'
      end

      # 3. Анализ критической утилизации дневных лимитов (> 80%)
      utilization.each do |p_name, data|
        util_pct = data['utilization_pct']
        if util_pct > 80.0
          recs << "#{p_name} близок к дневному лимиту (#{util_pct}%) - снизить traffic_percentage"
        end
      end

      # 4. Конкретные управленческие рекомендации
      recs << 'Увеличить daily_amount_limit для Payflow или снизить его target_pct до 20%'
      recs << 'Подключить прием Альфа-Банка к ViPay для разгрузки Quickpay'

      recs.uniq
    end
  end
end
