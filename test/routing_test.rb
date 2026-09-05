# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'tmpdir'
require 'open3'
require 'rbconfig'
require_relative '../lib/engine/payment_router'
require_relative '../lib/analytics/history_calibrator'

class RoutingTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  START = Time.iso8601('2026-07-30T12:00:00+03:00')

  def provider(name = 'gateway_a', **overrides)
    { 'payment_system' => name, 'status' => 'active', 'traffic_percentage' => 50,
      'priority' => 1, 'available_requisites' => 10, 'avg_latency_sec' => 38,
      'conversion_24h' => 0.8 }.merge(overrides.transform_keys(&:to_s))
  end

  def operation(id, seconds = 0, **overrides)
    { 'operation_id' => id.to_s, 'created_at' => (START + Rational(seconds.to_s)).iso8601(3),
      'amount' => 100, 'bank' => 'bank_a' }.merge(overrides.transform_keys(&:to_s))
  end

  def decision(provider_name, **overrides)
    { 'selected_provider' => provider_name, 'bank' => 'bank_a', 'amount' => 100,
      'created_at' => START.iso8601, 'attempts' => [], 'simulated_result' => 'approved' }
      .merge(overrides.transform_keys(&:to_s))
  end

  def report(raw_providers, decisions = [], **options)
    Analytics::ReportGenerator.generate(raw_providers.map { |p| Models::Provider.new(p) }, decisions, {}, **options)
  end

  def recommendations(*args, **options)
    report(*args, **options)['recommendations'].join("\n")
  end

  def test_rpm_burst_and_exact_sixty_second_boundary
    router = Engine::PaymentRouter.new([provider(requests_per_minute_limit: 2)])
    decisions, = router.route_all([operation(1), operation(2), operation(3, 59), operation(4, 60), operation(5, 60.001)])
    assert_equal %w[gateway_a gateway_a spacepayments spacepayments gateway_a], decisions.map { |d| d['selected_provider'] }
    decisions[2..3].each do |d|
      assert_equal 'skipped', d['attempts'].first['decision']
      assert_equal 'rpm_limit_exceeded', d['attempts'].first['reason']
    end
    assert_equal [START + Rational('60.001')], router.providers.first.request_timestamps
  end

  def test_rpm_candidates_do_not_consume_requests
    router = Engine::PaymentRouter.new([provider, provider('gateway_b', priority: 2, requests_per_minute_limit: 1)])
    router.route_all([operation(1), operation(2)])
    assert_empty router.providers[1].request_timestamps
  end

  def test_rpm_is_per_provider_and_skips_do_not_increment_it
    router = Engine::PaymentRouter.new([provider(requests_per_minute_limit: 1), provider('gateway_b', priority: 2, requests_per_minute_limit: 1)])
    decisions, = router.route_all([operation(1), operation(2), operation(3)])
    assert_equal %w[gateway_a gateway_b spacepayments], decisions.map { |d| d['selected_provider'] }
    assert_equal 1, router.providers.first.request_timestamps.size
    assert_equal 1, router.providers[1].request_timestamps.size
  end

  def test_missing_rpm_limit_is_unlimited_and_zero_disables_requests
    unlimited, = Engine::PaymentRouter.new([provider]).route_all(20.times.map { |i| operation(i) })
    assert unlimited.all? { |d| d['selected_provider'] == 'gateway_a' }
    blocked, = Engine::PaymentRouter.new([provider(requests_per_minute_limit: 0)]).route_all([operation(1)])
    assert_equal 'rpm_limit_exceeded', blocked.first['attempts'].first['reason']
  end

  def test_fallback_cannot_bypass_its_rpm_limit
    router = Engine::PaymentRouter.new([provider(requests_per_minute_limit: 0), provider('spacepayments', requests_per_minute_limit: 1)])
    decisions, report = router.route_all([operation(1), operation(2)])
    assert_nil decisions.last['selected_provider']
    assert_equal 'rejected', decisions.last['simulated_result']
    assert_equal 'rpm_limit_exceeded', decisions.last['attempts'].last['reason']
    assert_equal 1, report['distribution']['spacepayments']['count']
    assert_equal 100, router.providers.last.daily_approved_amount
  end

  def test_unsorted_queue_routes_by_time_and_returns_input_order
    router = Engine::PaymentRouter.new([provider(requests_per_minute_limit: 1)])
    decisions, = router.route_all([operation('late', 30), operation('early', 0)])
    assert_equal %w[late early], decisions.map { |d| d['operation_id'] }
    assert_equal %w[spacepayments gateway_a], decisions.map { |d| d['selected_provider'] }
    assert_raises(ArgumentError) { router.route_operation(Models::Operation.new(operation('older', 0))) }
  end

  def test_rpm_timestamps_use_absolute_time_with_timezone_offsets
    router = Engine::PaymentRouter.new([provider(requests_per_minute_limit: 1)])
    decisions, = router.route_all([operation(1), operation(2, created_at: '2026-07-30T09:00:30Z')])
    assert_equal 'spacepayments', decisions.last['selected_provider']
  end

  def test_latency_is_variable_and_stays_within_passport_range
    [10, 38, 90].each do |average|
      router = Engine::PaymentRouter.new([provider(avg_latency_sec: average)], random: Random.new(42))
      decisions, = router.route_all(100.times.map { |i| operation(i, i) })
      latencies = decisions.map { |d| d['latency_sec'] }
      assert latencies.all? { |value| value >= average * 0.85 && value <= average * 1.15 }
      assert_operator latencies.uniq.size, :>, 1
      assert_in_delta average, latencies.sum / latencies.size, average * 0.03
    end
  end

  def test_no_fact_means_no_recommendation
    assert_empty report([provider, provider('gateway_b')])['recommendations']
    assert_empty report([provider], [decision('gateway_a')])['recommendations']
  end

  def test_critical_utilization_threshold_and_computed_parameters
    assert_empty recommendations([provider(daily_amount_limit: 1000, daily_approved_amount: 800)])
    text = recommendations([provider(daily_amount_limit: 1000, daily_approved_amount: 900)])
    assert_includes text, 'gateway_a исчерпал 90.0%'
    assert_includes text, 'остаток: 100.0 ₽'
    assert_includes text, 'daily_amount_limit на 125 ₽'
    assert_includes text, 'с 50.0% до 44.44%'
  end

  def test_bank_monopoly_uses_actual_banks_and_counts_for_arbitrary_names
    providers = [provider('wide', traffic_percentage: 25), provider('narrow', banks: ['bank_b'])]
    decisions = [decision('wide'), decision('wide'), decision('wide', bank: 'bank_b'), decision('narrow', bank: 'bank_b')]
    text = recommendations(providers, decisions)
    assert_includes text, 'Перерасход квоты wide (+50.0 п.п.)'
    assert_includes text, 'банков bank_a (2 заявок)'
    assert_includes text, 'подключить шлюзы narrow'
  end

  def test_bank_monopoly_does_not_fire_at_ten_point_drift_or_without_exclusive_banks
    decisions = [decision('wide')] + Array.new(3) { decision('narrow', bank: 'bank_b') }
    assert_empty recommendations([provider('wide', traffic_percentage: 15), provider('narrow', banks: ['bank_b'])], decisions)
    decisions = Array.new(4) { decision('wide') }
    assert_empty recommendations([provider('wide', traffic_percentage: 25), provider('narrow')], decisions)
  end

  def test_bank_blacklist_is_used_for_monopoly_detection
    providers = [provider('wide', traffic_percentage: 25), provider('narrow', banks: ['bank_a'], exclude_banks: true)]
    assert_includes recommendations(providers, [decision('wide')]), 'банков bank_a (1 заявок)'
  end

  def test_amount_ceiling_requires_frequent_skips_for_that_provider
    providers = [provider('small', traffic_percentage: 60, priority: 2, limit_amount_max: 50), provider('large')]
    operations = [operation(1), operation(2)] + 3.times.map { |i| operation(i + 3, amount: 40) }
    _, output = Engine::PaymentRouter.new(providers).route_all(operations)
    assert_includes output['recommendations'].join, 'потолка суммы 50.0 ₽ (2 операций отсеяно)'
    _, output = Engine::PaymentRouter.new(providers).route_all(operations.drop(1))
    refute_includes output['recommendations'].join, 'потолка суммы'
  end

  def test_reliability_uses_history_and_computes_safe_slots
    history = { 'gateway_a' => { 'banks' => {
      'unstable' => { 'operation_count' => 10, 'expired_count' => 4, 'rejected_count' => 1 },
      'good' => { 'operation_count' => 10, 'expired_count' => 0, 'rejected_count' => 0 }
    } } }
    text = recommendations([provider(in_progress_count_limit: 8)], [], history_statistics: history)
    assert_includes text, 'gateway_a на банках unstable'
    assert_includes text, 'in_progress_count_limit до 4 слотов'
    refute_includes text, 'good'
  end

  def test_reliability_uses_observed_queue_failure_without_history
    operations = [operation(1, status: 'expired', payment_system: 'gateway_a')]
    _, output = Engine::PaymentRouter.new([provider(in_progress_count_limit: 8)]).route_all(operations)
    assert_includes output['recommendations'].join, 'gateway_a на банках bank_a'
    assert_includes output['recommendations'].join, 'до 1 слотов'
  end

  def test_minimum_turnover_uses_event_time_and_daily_progress
    providers = [provider(daily_turnover_min: 1000, daily_approved_amount: 499)]
    output = report(providers, [decision('gateway_a')])
    assert_equal '2026-07-30', output['period']
    assert_equal 500, output['daily_turnover_progress']['gateway_a']['expected_by_now']
    assert_includes output['recommendations'].join, 'факт: 499.0 ₽'
    assert_empty recommendations([provider(daily_turnover_min: 1000, daily_approved_amount: 500)], [decision('gateway_a')])
    assert_empty recommendations(providers) # Нет времени прогона — нет выдуманного графика.
  end

  def test_distribution_uses_current_queue_instead_of_seeded_processed_counters
    output = report([provider(processed_count: 100, processed_volume: 10_000)], [decision('gateway_a')])
    assert_equal 1, output['distribution']['gateway_a']['count']
    assert_equal 100, output['distribution']['gateway_a']['volume_rub']
  end

  def test_calibration_aggregates_all_hundred_operations_without_rounding_sr
    result = Analytics::HistoryCalibrator.new(File.join(ROOT, 'data/operations_history.csv')).calibrate
    assert_equal 100, result['statistics']['overall']['operation_count']
    assert_equal 68, result['statistics']['overall']['approved_count']
    payflow = result['statistics']['providers']['payflow']
    assert_equal 19, payflow['operation_count']
    assert_equal 7, payflow['expired_count']
    assert_in_delta 9.0 / 19, payflow['success_rate']
    assert_in_delta 2.0 / 7, result['strategy']['bank_success_rates']['payflow']['alfa']
    assert_equal 0.0, result['strategy']['bank_success_rates']['payflow']['tinkoff']
    assert_equal 7, payflow['failures']['expired']['reasons']['unspecified']['count']
    rows = CSV.read(File.join(ROOT, 'data/operations_history.csv'), headers: true).select { |row| row['payment_system'] == 'payflow' }
    assert_in_delta rows.sum { |row| row['amount'].to_f } / 19, payflow['average_amount']
  end

  def with_history
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'history.csv')
      File.write(path, "operation_id,created_at,amount,bank,payment_system,status,reason\n1,2026-07-30T12:00:00Z,100,bank_a,custom,approved,\n2,2026-07-30T12:01:00Z,300,bank_a,custom,expired,timeout\n3,2026-07-30T12:02:00Z,200,bank_b,custom,rejected,bank_declined\n")
      yield dir, path
    end
  end

  def test_calibration_tracks_failure_reasons_and_changes_with_data
    with_history do |_dir, path|
      result = Analytics::HistoryCalibrator.new(path).calibrate
      assert_equal 0.5, result['strategy']['bank_success_rates']['custom']['bank_a']
      assert_equal 200, result['statistics']['providers']['custom']['average_amount']
      reasons = result['statistics']['overall']['failures']
      assert_equal 1, reasons['expired']['reasons']['timeout']['count']
      assert_equal 1, reasons['rejected']['reasons']['bank_declined']['count']
      File.write(path, File.read(path).gsub('expired', 'approved').gsub('rejected', 'approved'))
      updated = Analytics::HistoryCalibrator.new(path).calibrate
      assert_equal 1, updated['strategy']['bank_success_rates']['custom']['bank_a']
      refute_equal result['strategy']['w_conv'], updated['strategy']['w_conv']
      refute_equal result['strategy']['w_util'], updated['strategy']['w_util']
    end
  end

  def test_calibration_script_preserves_other_config_and_is_idempotent
    with_history do |dir, path|
      config_path = File.join(dir, 'config.json')
      File.write(config_path, JSON.generate('default_strategy' => 'priority_cascade', 'custom' => true,
                                           'strategies' => { 'hybrid_adaptive' => { 'custom_weight' => 42 } }))
      2.times do
        output, status = Open3.capture2e(RbConfig.ruby, File.join(ROOT, 'scripts/calibrate.rb'), path, config_path)
        assert status.success?, output
        json = JSON.parse(File.read(config_path))
        assert json['custom']
        assert_equal 'priority_cascade', json['default_strategy']
        assert_equal 42, json['strategies']['hybrid_adaptive']['custom_weight']
        assert_equal 0.5, json['strategies']['hybrid_adaptive']['bank_success_rates']['custom']['bank_a']
        if @previous_config
          assert_equal @previous_config, File.read(config_path)
        end
        @previous_config = File.read(config_path)
      end
    end
  end

  def test_invalid_history_does_not_overwrite_config
    with_history do |dir, path|
      config_path = File.join(dir, 'config.json')
      File.write(config_path, '{"keep":true}')
      File.write(path, 'invalid csv')
      _, status = Open3.capture2e(RbConfig.ruby, File.join(ROOT, 'scripts/calibrate.rb'), path, config_path)
      refute status.success?
      assert_equal '{"keep":true}', File.read(config_path)
    end
  end

  def test_scoring_reads_config_matrix_including_zero_and_uses_fallbacks
    config = { 'bank_success_rates' => { 'gateway_a' => { 'bank_a' => 0.0 }, 'gateway_b' => { 'bank_a' => 1.0 } },
               'provider_success_rates' => { 'gateway_a' => 0.4 }, 'default_success_rate' => 0.6 }
    strategy = Strategies::HybridAdaptiveStrategy.new(config)
    assert_equal 0.0, strategy.bank_success_rate('gateway_a', 'bank_a')
    assert_equal 0.4, strategy.bank_success_rate('gateway_a', 'new_bank')
    assert_equal 0.6, strategy.bank_success_rate('new_provider', 'new_bank')
    router = Engine::PaymentRouter.new([provider, provider('gateway_b', priority: 2)], strategy_name: 'hybrid_adaptive', config: config)
    decisions, = router.route_all([operation(1)])
    assert_equal 'gateway_b', decisions.first['selected_provider']
    assert_includes decisions.first['attempts'].last['details'], 'sr=1.0'
  end
end
