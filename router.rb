#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'date'

# Подключение модулей архитектуры
require_relative 'lib/models/provider'
require_relative 'lib/models/operation'
require_relative 'lib/filters/hard_constraints_filter'
require_relative 'lib/strategies/scoring_strategy'
require_relative 'lib/engine/payment_router'
require_relative 'lib/analytics/report_generator'

# 1. Считывание аргументов командной строки и конфигурации
providers_path = ARGV[0] || 'data/providers.json'
queue_path     = ARGV[1] || (File.exist?('data/operations_queue_10.json') ? 'data/operations_queue_10.json' : 'data/operations_queue.json')
out_decisions  = ARGV[2] || 'routing_decisions.json'
out_report     = ARGV[3] || 'routing_report.json'
strategy_param = ARGV[4]

config = {}
config_path = File.expand_path('config.json', __dir__)
if File.exist?(config_path)
  begin
    config = JSON.parse(File.read(config_path))
  rescue JSON::ParserError => e
    warn "⚠️  Ошибка чтения config.json: #{e.message}. Используются значения по умолчанию."
  end
end

active_strategy = strategy_param || ENV['ROUTING_STRATEGY'] || config['default_strategy'] || 'priority_cascade'
strategy_config_name = %w[scoring adaptive].include?(active_strategy.downcase) ? 'hybrid_adaptive' : active_strategy.downcase
strategy_config = (config['strategies'] && config['strategies'][strategy_config_name]) || {}

# 2. Проверка входных файлов
unless File.exist?(providers_path)
  warn "❌ Файл провайдеров не найден: #{providers_path}"
  exit 1
end

unless File.exist?(queue_path)
  warn "❌ Файл очереди операций не найден: #{queue_path}"
  exit 1
end

begin
  providers_raw = JSON.parse(File.read(providers_path))
  queue_raw = JSON.parse(File.read(queue_path))
rescue JSON::ParserError => e
  warn "❌ Ошибка парсинга JSON: #{e.message}"
  exit 1
end

providers_list = providers_raw.is_a?(Hash) ? providers_raw['providers'] : providers_raw
queue_list     = queue_raw.is_a?(Array) ? queue_raw : [queue_raw]

# 3. Запуск роутера
router = Engine::PaymentRouter.new(
  providers_list,
  strategy_name: active_strategy,
  config: strategy_config,
  history_statistics: config.dig('calibration', 'providers') || {}
)

decisions, report = router.route_all(queue_list)

# 4. Сохранение выходных артефактов
File.write(out_decisions, JSON.pretty_generate(decisions))
File.write(out_report, JSON.pretty_generate(report))

puts "========================================================"
puts "  Smart Payout Router (Чистый Ruby)"
puts "========================================================"
puts "  Стратегия: #{active_strategy}"
puts "  Обработано операций: #{decisions.size}"
puts "  📁 Решения: #{out_decisions}"
puts "  📊 Отчет:   #{out_report}"
puts "========================================================"
