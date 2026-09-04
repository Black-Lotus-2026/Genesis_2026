# frozen_string_literal: true

require_relative '../models/provider'
require_relative '../models/operation'
require_relative '../filters/hard_constraints_filter'
require_relative '../strategies/scoring_strategy'
require_relative '../analytics/report_generator'

module Engine
  # Основной движок умной маршрутизации выплат (Smart Payout Router)
  class PaymentRouter
    FALLBACK_SYSTEM = Models::Provider::FALLBACK_SYSTEM

    attr_reader :providers, :strategy, :skip_reasons_counter, :total_operations, :total_volume

    def initialize(providers_data, strategy_name: 'priority_cascade', config: {})
      # Глубокое копирование и инициализация доменных моделей
      raw_providers = providers_data.is_a?(Hash) ? providers_data['providers'] : providers_data
      @providers = raw_providers.map { |p| Models::Provider.new(p) }
      @strategy = Strategies::StrategyFactory.create(strategy_name, config)
      @skip_reasons_counter = Hash.new(0)
      @total_operations = 0
      @total_volume = 0.0
    end

    def route_all(queue)
      operations = queue.map { |op| op.is_a?(Models::Operation) ? op : Models::Operation.new(op) }
      decisions = operations.map { |op| route_operation(op) }
      report = Analytics::ReportGenerator.generate(@providers, decisions, @skip_reasons_counter)
      [decisions, report]
    end

    def route_operation(operation)
      commercial_providers = @providers.reject(&:fallback?).sort_by(&:priority)
      attempts = []
      eligible = []

      # 1. Проверка жестких ограничений (Hard-constraints) для каждого коммерческого провайдера
      commercial_providers.each do |provider|
        is_eligible, skip_reason, skip_details = Filters::HardConstraintsFilter.evaluate(provider, operation)

        if is_eligible
          eligible << provider
        else
          attempts << {
            'provider' => provider.payment_system,
            'decision' => 'skipped',
            'reason' => skip_reason,
            'details' => skip_details
          }
          @skip_reasons_counter[skip_reason] += 1
        end
      end

      # 2. Выбор победителя через активную стратегию либо fallback
      winner = nil
      if eligible.any?
        context = {
          total_operations: @total_operations,
          total_volume: @total_volume
        }
        winner, reason, details = @strategy.select_provider(eligible, operation, context)

        attempts << {
          'provider' => winner.payment_system,
          'decision' => 'selected',
          'reason' => reason,
          'details' => details
        }
      else
        # Level 4 Fallback: переход на spacepayments
        fallback_provider = @providers.find(&:fallback?) || Models::Provider.new({
          'payment_system' => FALLBACK_SYSTEM,
          'priority' => 99,
          'avg_latency_sec' => 15
        })
        winner = fallback_provider
        attempts << {
          'provider' => FALLBACK_SYSTEM,
          'decision' => 'selected',
          'reason' => 'fallback_provider',
          'details' => 'All commercial providers ineligible, routed to fallback gateway'
        }
      end

      # 3. Детерминированная сортировка попыток по возрастанию приоритета
      attempts.sort_by! do |att|
        prov = @providers.find { |p| p.payment_system == att['provider'] }
        prov ? prov.priority : 999
      end

      # 4. Обновление состояния и метрик
      winner.approve_operation!(operation.amount)
      @total_operations += 1
      @total_volume += operation.amount

      # 5. Моделирование задержки (в диапазоне 15..60 секунд)
      latency = [[winner.avg_latency_sec, 15].max, 60].min

      {
        'operation_id' => operation.operation_id,
        'selected_provider' => winner.payment_system,
        'attempts' => attempts,
        'simulated_result' => 'approved',
        'latency_sec' => latency
      }
    end
  end
end
