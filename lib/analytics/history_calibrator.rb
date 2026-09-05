# frozen_string_literal: true

require 'csv'
require 'digest'

module Analytics
  # Воспроизводимая калибровка стартовых весов; оптимизацию по holdout не заменяет.
  class HistoryCalibrator
    REQUIRED_COLUMNS = %w[operation_id created_at amount bank payment_system status].freeze
    FAILURE_STATUSES = %w[expired rejected].freeze

    def initialize(history_path)
      @history_path = history_path
    end

    def calibrate
      table = CSV.read(@history_path, headers: true, encoding: 'bom|utf-8')
      missing = REQUIRED_COLUMNS - Array(table.headers)
      raise ArgumentError, "Missing CSV columns: #{missing.join(', ')}" unless missing.empty?
      raise ArgumentError, 'History CSV contains no operations' if table.empty?

      rows = table.map.with_index(2) do |row, line|
        data = row.to_h
        REQUIRED_COLUMNS.each do |key|
          raise ArgumentError, "Empty #{key} at CSV line #{line}" if data[key].to_s.strip.empty?
        end
        amount = Float(data['amount'])
        raise ArgumentError, "Invalid amount at CSV line #{line}" unless amount.finite? && amount.positive?

        data.merge('amount' => amount)
      end
      ids = rows.map { |row| row['operation_id'] }
      raise ArgumentError, 'Duplicate operation_id in history CSV' unless ids.uniq.size == ids.size

      providers = rows.group_by { |row| row['payment_system'] }.sort.to_h.transform_values do |provider_rows|
        summarize(provider_rows).merge(
          'banks' => provider_rows.group_by { |row| row['bank'] }.sort.to_h.transform_values { |bank_rows| summarize(bank_rows) }
        )
      end
      overall = summarize(rows)
      matrix = providers.transform_values { |stats| stats['banks'].transform_values { |bank| bank['success_rate'] } }
      weights = calculate_weights(rows, overall, matrix)
      {
        'strategy' => weights.merge(
          'bank_success_rates' => matrix,
          'provider_success_rates' => providers.transform_values { |stats| stats['success_rate'] },
          'default_success_rate' => overall['success_rate']
        ),
        'statistics' => {
          'history_file' => File.basename(@history_path),
          'history_sha256' => Digest::SHA256.file(@history_path).hexdigest,
          'weight_method' => 'empirical_initial_weights_v1',
          'overall' => overall,
          'providers' => providers
        }
      }
    end

    private

    def summarize(rows)
      statuses = rows.group_by { |row| row['status'] }.transform_values(&:size)
      count = rows.size
      {
        'operation_count' => count,
        'approved_count' => statuses.fetch('approved', 0),
        'expired_count' => statuses.fetch('expired', 0),
        'rejected_count' => statuses.fetch('rejected', 0),
        'status_counts' => statuses.sort.to_h,
        'success_rate' => statuses.fetch('approved', 0).to_f / count,
        'average_amount' => rows.sum { |row| row['amount'] } / count,
        'failures' => FAILURE_STATUSES.each_with_object({}) do |status, failures|
          failed_rows = rows.select { |row| row['status'] == status }
          reasons = failed_rows.group_by do |row|
            [row["#{status}_reason"], row['failure_reason'], row['reason']].find { |reason| !reason.to_s.strip.empty? } || 'unspecified'
          end
          failures[status] = {
            'count' => failed_rows.size,
            'share_pct' => failed_rows.size.to_f / count * 100,
            'reasons' => reasons.sort.to_h.transform_values do |reason_rows|
              { 'count' => reason_rows.size, 'share_pct' => reason_rows.size.to_f / failed_rows.size * 100 }
            end
          }
        end
      }
    end

    def calculate_weights(rows, overall, matrix)
      count = rows.size.to_f
      mean = overall['average_amount']
      amount_variation = Math.sqrt(rows.sum { |row| (row['amount'] - mean)**2 } / count) / mean
      failure_rate = (overall['expired_count'] + overall['rejected_count']) / count
      expired_rate = overall['expired_count'] / count
      conversion_weight = [100 * failure_rate, 1.0].max
      utilization_weight = [100 * expired_rate, 1.0].max
      {
        'w_count' => 1.0,
        'w_vol' => (1 + amount_variation).round(6),
        'w_conv' => conversion_weight.round(6),
        'w_util' => utilization_weight.round(6),
        'w_prio' => overall['success_rate'].round(6),
        'penalty_util_high' => (conversion_weight + utilization_weight).round(6),
        'penalty_low_sr' => [100 * (1 - matrix.values.flat_map(&:values).min), 1.0].max.round(6)
      }
    end
  end
end
