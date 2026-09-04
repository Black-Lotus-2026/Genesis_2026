# frozen_string_literal: true

module Strategies
  # Базовый абстрактный класс стратегии маршрутизации
  class BaseStrategy
    attr_reader :name, :config

    def initialize(name, config = {})
      @name = name
      @config = config || {}
    end

    # Основной контракт выбора провайдера среди допущенных (eligible)
    # Возвращает [selected_provider, reason, details]
    def select_provider(eligible_providers, operation, context = {})
      raise NotImplementedError, "#{self.class}#select_provider must be implemented"
    end

    protected

    def calculate_count_share(provider, total_ops)
      return 0.0 if total_ops.to_i.zero?

      ((provider.processed_count.to_f / total_ops) * 100.0).round(4)
    end

    def calculate_volume_share(provider, total_vol)
      return 0.0 if total_vol.to_f.zero?

      ((provider.processed_volume.to_f / total_vol) * 100.0).round(4)
    end

    def delta_count(provider, total_ops)
      (provider.traffic_percentage - calculate_count_share(provider, total_ops)).round(4)
    end

    def delta_volume(provider, total_vol)
      (provider.traffic_percentage - calculate_volume_share(provider, total_vol)).round(4)
    end
  end
end
