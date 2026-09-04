# frozen_string_literal: true

module Models
  # Модель платежного провайдера с динамическим отслеживанием состояния
  class Provider
    FALLBACK_SYSTEM = 'spacepayments'

    attr_reader :payment_system, :status, :traffic_percentage, :priority,
                :limit_amount_min, :limit_amount_max, :daily_amount_limit,
                :in_progress_count_limit, :in_progress_amount_limit,
                :conversion_24h, :avg_latency_sec, :banks, :exclude_banks,
                :provider_margin_pct, :merchant_margin_pct, :allow_negative_agreement,
                :note, :raw_data

    attr_accessor :daily_approved_amount, :in_progress_count, :in_progress_amount,
                  :available_requisites, :processed_count, :processed_volume

    def initialize(data)
      @raw_data = data
      @payment_system = data['payment_system'].to_s
      @status = data['status'].to_s
      @traffic_percentage = data['traffic_percentage'].to_f
      @priority = data['priority'].to_i
      @limit_amount_min = data['limit_amount_min'] ? data['limit_amount_min'].to_f : nil
      @limit_amount_max = data['limit_amount_max'] ? data['limit_amount_max'].to_f : nil
      @daily_amount_limit = data['daily_amount_limit'] ? data['daily_amount_limit'].to_f : nil
      @daily_approved_amount = data['daily_approved_amount'].to_f
      @in_progress_count_limit = data['in_progress_count_limit'] ? data['in_progress_count_limit'].to_i : nil
      @in_progress_count = data['in_progress_count'].to_i
      @in_progress_amount_limit = data['in_progress_amount_limit'] ? data['in_progress_amount_limit'].to_f : nil
      @in_progress_amount = data['in_progress_amount'].to_f
      @available_requisites = data['available_requisites'].to_i
      @conversion_24h = data['conversion_24h'].to_f
      @avg_latency_sec = data['avg_latency_sec'] ? data['avg_latency_sec'].to_i : 30
      @banks = Array(data['banks']).map(&:to_s)
      @exclude_banks = data['exclude_banks'] == true
      @provider_margin_pct = data['provider_margin_pct'].to_f
      @merchant_margin_pct = data['merchant_margin_pct'].to_f
      @allow_negative_agreement = data['allow_negative_agreement'] == true
      @note = data['note']

      @processed_count = data['processed_count'].to_i
      @processed_volume = data['processed_volume'].to_f
    end

    def fallback?
      @payment_system == FALLBACK_SYSTEM
    end

    def active?
      @status == 'active'
    end

    def utilization_rate
      return 0.0 unless @daily_amount_limit && @daily_amount_limit.positive?

      @daily_approved_amount / @daily_amount_limit
    end

    def utilization_pct
      (utilization_rate * 100.0).round(2)
    end

    def approve_operation!(amount)
      @daily_approved_amount += amount
      @processed_count += 1
      @processed_volume += amount
    end

    def to_h
      {
        'payment_system' => @payment_system,
        'status' => @status,
        'traffic_percentage' => @traffic_percentage,
        'priority' => @priority,
        'limit_amount_min' => @limit_amount_min,
        'limit_amount_max' => @limit_amount_max,
        'daily_amount_limit' => @daily_amount_limit,
        'daily_approved_amount' => @daily_approved_amount,
        'in_progress_count_limit' => @in_progress_count_limit,
        'in_progress_count' => @in_progress_count,
        'in_progress_amount_limit' => @in_progress_amount_limit,
        'in_progress_amount' => @in_progress_amount,
        'available_requisites' => @available_requisites,
        'conversion_24h' => @conversion_24h,
        'avg_latency_sec' => @avg_latency_sec,
        'banks' => @banks,
        'exclude_banks' => @exclude_banks,
        'provider_margin_pct' => @provider_margin_pct,
        'merchant_margin_pct' => @merchant_margin_pct,
        'allow_negative_agreement' => @allow_negative_agreement,
        'processed_count' => @processed_count,
        'processed_volume' => @processed_volume
      }
    end
  end
end
