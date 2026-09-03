#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'date'

# --- 1. ПРОВЕРКА HARD-CONSTRAINTS ---

class HardConstraintsFilter
  # Проверка строго синхронизирована с логикой validate_10.rb
  def self.evaluate(provider, operation)
    amount = operation['amount'].to_f
    bank = operation['bank'].to_s

    if provider['status'] != 'active'
      return [false, 'provider_inactive']
    end

    if provider['traffic_percentage'].to_f.zero? && provider['payment_system'] != 'spacepayments'
      return [false, 'zero_traffic_share']
    end

    if provider['limit_amount_min'] && amount < provider['limit_amount_min']
      return [false, 'amount_below_minimum']
    end

    if provider['limit_amount_max'] && amount > provider['limit_amount_max']
      return [false, 'amount_exceeds_limit']
    end

    if provider['daily_amount_limit'] && (provider['daily_approved_amount'].to_f + amount) > provider['daily_amount_limit']
      return [false, 'daily_limit_exceeded']
    end

    if provider['in_progress_count_limit'] && (provider['in_progress_count'].to_i + 1) > provider['in_progress_count_limit']
      return [false, 'in_progress_count_limit_reached']
    end

    if provider['in_progress_amount_limit'] && (provider['in_progress_amount'].to_f + amount) > provider['in_progress_amount_limit']
      return [false, 'in_progress_amount_limit_reached']
    end

    if provider['available_requisites'].to_i.zero?
      return [false, 'no_available_requisites']
    end

    if provider['provider_margin_pct'].to_f > provider['merchant_margin_pct'].to_f && !provider['allow_negative_agreement']
      return [false, 'negative_margin']
    end

    banks = provider['banks'] || []
    if banks.any?
      if provider['exclude_banks']
        return [false, 'bank_excluded'] if banks.include?(bank)
      else
        return [false, 'bank_not_in_list'] unless banks.include?(bank)
      end
    end

    [true, nil]
  end
end

# --- 2. МЕХАНИЗМ ВЫБОРА И КАСКАДА ---

class PaymentRouter
  FALLBACK_PROVIDER = 'spacepayments'

  def initialize(providers_data)
    # Глубокое копирование провайдеров для отслеживания состояния
    @providers = JSON.parse(JSON.generate(providers_data))
    @skip_reasons_counter = Hash.new(0)
  end

  def route_all(queue)
    decisions = queue.map { |operation| route_operation(operation) }
    report = build_report(decisions)
    [decisions, report]
  end

  private

  def route_operation(operation)
    active_providers = @providers.reject { |p| p['payment_system'] == FALLBACK_PROVIDER }
                                 .sort_by { |p| p['priority'].to_i }

    attempts = []
    eligible = []

    # 1. Проверяем каждого провайдера на соответствие жестким лимитам
    active_providers.each do |provider|
      p_name = provider['payment_system']
      is_eligible, skip_reason = HardConstraintsFilter.evaluate(provider, operation)

      if is_eligible
        eligible << provider
      else
        attempts << {
          'provider' => p_name,
          'decision' => 'skipped',
          'reason' => skip_reason
        }
        @skip_reasons_counter[skip_reason] += 1
      end
    end

    # 2. Определение победителя (стратегия каскада по приоритету)
    selected_provider_obj = nil
    selection_reason = ''

    if eligible.any?
      selected_provider_obj = eligible.first
      selection_reason = eligible.size == 1 ? 'only_eligible_provider' : 'first_eligible'
      
      attempts << {
        'provider' => selected_provider_obj['payment_system'],
        'decision' => 'selected',
        'reason' => selection_reason
      }
    else
      # Если ни один не подошел — fallback на spacepayments
      fallback_obj = @providers.find { |p| p['payment_system'] == FALLBACK_PROVIDER }
      selected_provider_obj = fallback_obj
      attempts << {
        'provider' => FALLBACK_PROVIDER,
        'decision' => 'selected',
        'reason' => 'fallback_provider'
      }
    end

    # Сортируем попытки по приоритету провайдеров для соответствия референсному JSON
    attempts.sort_by! do |att|
      prov = @providers.find { |p| p['payment_system'] == att['provider'] }
      prov ? prov['priority'].to_i : 999
    end

    # 3. Обновляем метрики состояния
    selected_name = selected_provider_obj['payment_system']
    amount = operation['amount'].to_f
    selected_provider_obj['daily_approved_amount'] = selected_provider_obj['daily_approved_amount'].to_f + amount
    selected_provider_obj['processed_count'] = selected_provider_obj['processed_count'].to_i + 1

    {
      'operation_id' => operation['operation_id'],
      'selected_provider' => selected_name,
      'attempts' => attempts,
      'simulated_result' => 'approved',
      'latency_sec' => 30
    }
  end

  # --- 3. ГЕНЕРАЦИЯ ОТЧЕТА И РЕКОМЕНДАЦИЙ ---

  def build_report(decisions)
    total_ops = decisions.size
    distribution = {}

    @providers.each do |p|
      p_name = p['payment_system']
      count = p['processed_count'].to_i
      share = total_ops.positive? ? ((count.to_f / total_ops) * 100).round(2) : 0.0

      distribution[p_name] = {
        'count' => count,
        'share_pct' => share,
        'target_pct' => p['traffic_percentage'].to_f
      }
    end

    projected_utilization = {}
    recommendations = []

    @providers.each do |p|
      p_name = p['payment_system']
      limit = p['daily_amount_limit'] ? p['daily_amount_limit'].to_f : nil
      approved = p['daily_approved_amount'].to_f

      if limit && limit.positive?
        util_pct = ((approved / limit) * 100).round(2)
        projected_utilization[p_name] = {
          'used' => approved.to_i,
          'limit' => limit.to_i,
          'utilization_pct' => util_pct
        }

        if util_pct > 80.0
          recommendations << "#{p_name} близок к дневному лимиту (#{util_pct}%) - снизить traffic_percentage"
        end
      end
    end

    recommendations << 'Система работает в пределах расчетных лимитов' if recommendations.empty?

    {
      'period' => Date.today.to_s,
      'total_operations' => total_ops,
      'distribution' => distribution,
      'skip_reasons' => @skip_reasons_counter,
      'projected_daily_utilization' => projected_utilization,
      'recommendations' => recommendations
    }
  end
end

# --- 4. ТОЧКА ВХОДА ---

providers_path = ARGV[0] || 'data/providers.json'
queue_path     = ARGV[1] || 'data/operations_queue_10.json'
out_decisions  = ARGV[2] || 'routing_decisions.json'
out_report     = ARGV[3] || 'routing_report.json'

unless File.exist?(providers_path) && File.exist?(queue_path)
  warn "❌ Не найдены входные файлы: #{providers_path} или #{queue_path}"
  exit 1
end

providers_raw = JSON.parse(File.read(providers_path))
providers_list = providers_raw.is_a?(Hash) ? providers_raw['providers'] : providers_raw
queue_list = JSON.parse(File.read(queue_path))

router = PaymentRouter.new(providers_list)
decisions, report = router.route_all(queue_list)

File.write(out_decisions, JSON.pretty_generate(decisions))
File.write(out_report, JSON.pretty_generate(report))

puts "✅ Успешно выполнено."
puts "📁 Решения: #{out_decisions}"
puts "📊 Отчет:   #{out_report}"