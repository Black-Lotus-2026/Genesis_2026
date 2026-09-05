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

    def initialize(providers_data, strategy_name: 'priority_cascade', config: {}, history_statistics: {}, random: Random.new)
      # Глубокое копирование и инициализация доменных моделей
      raw_providers = providers_data.is_a?(Hash) ? providers_data['providers'] : providers_data
      @providers = raw_providers.map { |p| Models::Provider.new(p) }
      @strategy = Strategies::StrategyFactory.create(strategy_name, config)
      @skip_reasons_counter = Hash.new(0)
      @total_operations = 0
      @total_volume = 0.0
      @history_statistics = history_statistics
      @random = random
      @last_operation_time = nil
    end

    def route_all(queue)
      operations = queue.map { |op| op.is_a?(Models::Operation) ? op : Models::Operation.new(op) }
      # RPM рассчитывается по времени событий, результат сохраняет порядок входа.
      decisions = Array.new(operations.size)
      operations.each_with_index.sort_by { |op, index| [op.created_time, index] }.each do |op, index|
        decisions[index] = route_operation(op)
      end
      report = Analytics::ReportGenerator.generate(
        @providers, decisions, @skip_reasons_counter,
        operations: operations, history_statistics: @history_statistics
      )
      [decisions, report]
    end

    def route_operation(operation)
      if @last_operation_time && operation.created_time < @last_operation_time
        raise ArgumentError, 'Operations must be routed in chronological order; use route_all for an unsorted queue'
      end
      @last_operation_time = operation.created_time
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
        fallback_provider = @providers.find(&:fallback?)
        unless fallback_provider
          fallback_provider = Models::Provider.new({
            'payment_system' => FALLBACK_SYSTEM, 'status' => 'active',
            'priority' => 99, 'avg_latency_sec' => 15, 'available_requisites' => 1
          })
          @providers << fallback_provider
        end
        allowed, skip_reason, skip_details = Filters::HardConstraintsFilter.evaluate(fallback_provider, operation)
        if allowed
          winner = fallback_provider
          attempts << {
            'provider' => FALLBACK_SYSTEM,
            'decision' => 'selected',
            'reason' => 'fallback_provider',
            'details' => 'All commercial providers ineligible, routed to fallback gateway'
          }
        else
          attempts << { 'provider' => FALLBACK_SYSTEM, 'decision' => 'skipped',
                        'reason' => skip_reason, 'details' => skip_details }
          @skip_reasons_counter[skip_reason] += 1
        end
      end

      # 3. Детерминированная сортировка попыток по возрастанию приоритета
      attempts.sort_by! do |att|
        prov = @providers.find { |p| p.payment_system == att['provider'] }
        prov ? prov.priority : 999
      end

      # 4. Обновление состояния и метрик
      if winner
        winner.record_request!(operation.created_time)
        winner.approve_operation!(operation.amount)
        @total_volume += operation.amount
      end
      @total_operations += 1

      # 5. Паспортная задержка с равномерным разбросом ±15%.
      latency = winner ? winner.avg_latency_sec * (0.85 + @random.rand * 0.30) : 0.0

      {
        'operation_id' => operation.operation_id,
        'created_at' => operation.created_at,
        'amount' => operation.amount,
        'bank' => operation.bank,
        'selected_provider' => winner&.payment_system,
        'attempts' => attempts,
        'simulated_result' => winner ? 'approved' : 'rejected',
        'latency_sec' => latency
      }
    end
  end
end
