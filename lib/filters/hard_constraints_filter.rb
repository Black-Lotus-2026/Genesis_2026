# frozen_string_literal: true

module Filters
  # Модуль строгой проверки жестких ограничений (Hard-constraints)
  # Возвращает [eligible?, reason, details]
  class HardConstraintsFilter
    def self.evaluate(provider, operation)
      amount = operation.amount
      bank = operation.bank
      provider.prune_request_timestamps!(operation.created_time)

      # 1. Статус провайдера
      unless provider.active?
        return [false, 'provider_inactive', "Provider status is '#{provider.status}', expected 'active'"]
      end

      # 2. Ненулевая доля трафика (для коммерческих провайдеров)
      if provider.traffic_percentage.zero? && !provider.fallback?
        return [false, 'zero_traffic_share', "Provider traffic_percentage is #{provider.traffic_percentage}%"]
      end

      # 3. Минимальная сумма операции
      if provider.limit_amount_min && amount < provider.limit_amount_min
        return [
          false,
          'amount_below_minimum',
          "#{amount.to_i} < limit_amount_min #{provider.limit_amount_min.to_i}"
        ]
      end

      # 4. Максимальная сумма операции
      if provider.limit_amount_max && amount > provider.limit_amount_max
        return [
          false,
          'amount_exceeds_limit',
          "#{amount.to_i} > limit_amount_max #{provider.limit_amount_max.to_i}"
        ]
      end

      # 5. Дневной лимит оборота
      if provider.daily_amount_limit && (provider.daily_approved_amount + amount) > provider.daily_amount_limit
        return [
          false,
          'daily_limit_exceeded',
          "Projected daily #{(provider.daily_approved_amount + amount).to_i} > limit #{provider.daily_amount_limit.to_i}"
        ]
      end

      # 6. Лимит одновременных операций по количеству
      if provider.in_progress_count_limit && (provider.in_progress_count + 1) > provider.in_progress_count_limit
        return [
          false,
          'in_progress_count_limit_reached',
          "in_progress_count #{provider.in_progress_count + 1} > limit #{provider.in_progress_count_limit}"
        ]
      end

      # 7. Лимит одновременных операций по сумме
      if provider.in_progress_amount_limit && (provider.in_progress_amount + amount) > provider.in_progress_amount_limit
        return [
          false,
          'in_progress_amount_limit_reached',
          "in_progress_amount #{(provider.in_progress_amount + amount).to_i} > limit #{provider.in_progress_amount_limit.to_i}"
        ]
      end

      # 8. Наличие свободных реквизитов
      if provider.available_requisites <= 0
        return [false, 'no_available_requisites', "available_requisites is #{provider.available_requisites}"]
      end

      # 9. Проверка маржинальности
      if provider.provider_margin_pct > provider.merchant_margin_pct && !provider.allow_negative_agreement
        return [
          false,
          'negative_margin',
          "provider_margin #{provider.provider_margin_pct}% > merchant_margin #{provider.merchant_margin_pct}%"
        ]
      end

      # 10. Банковский фильтр (whitelist / blacklist)
      banks = provider.banks
      if banks.any?
        if provider.exclude_banks
          if banks.include?(bank)
            return [false, 'bank_excluded', "bank '#{bank}' is in blacklist #{banks}"]
          end
        else
          unless banks.include?(bank)
            return [false, 'bank_not_in_list', "bank '#{bank}' not in whitelist #{banks}"]
          end
        end
      end

      # 11. Скользящий лимит интенсивности: проверки кандидатов не расходуют RPM.
      if provider.requests_per_minute_limit && provider.request_timestamps.size >= provider.requests_per_minute_limit
        return [false, 'rpm_limit_exceeded',
                "#{provider.request_timestamps.size} requests in the last 60 seconds >= limit #{provider.requests_per_minute_limit}"]
      end

      [true, nil, nil]
    end
  end
end
