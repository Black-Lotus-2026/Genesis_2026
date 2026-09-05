#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'tempfile'
require_relative '../lib/analytics/history_calibrator'

history_path = ARGV[0] || File.expand_path('../data/operations_history.csv', __dir__)
config_path = ARGV[1] || File.expand_path('../config.json', __dir__)

begin
  config = File.exist?(config_path) ? JSON.parse(File.read(config_path)) : {}
  raise ArgumentError, 'config.json must contain an object' unless config.is_a?(Hash)

  calibration = Analytics::HistoryCalibrator.new(history_path).calibrate
  config['strategies'] ||= {}
  config['strategies']['hybrid_adaptive'] ||= {}
  config['strategies']['hybrid_adaptive'].merge!(calibration['strategy'])
  config['calibration'] = calibration['statistics']

  # Заменяем config только после полного чтения и успешного расчета.
  Tempfile.create(['calibration', '.json'], File.dirname(File.expand_path(config_path))) do |file|
    file.write(JSON.pretty_generate(config) + "\n")
    file.flush
    file.fsync
    File.chmod(File.stat(config_path).mode & 0o777, file.path) if File.exist?(config_path)
    File.rename(file.path, config_path)
  end
  puts "Калибровка: #{calibration['statistics']['overall']['operation_count']} операций → #{config_path}"
rescue ArgumentError, TypeError, NoMethodError, CSV::MalformedCSVError, JSON::ParserError, SystemCallError => e
  warn "Ошибка калибровки: #{e.message}"
  exit 1
end
