# frozen_string_literal: true

require 'time'

module Models
  # Модель входящей операции/заявки на выплату
  class Operation
    attr_reader :operation_id, :created_at, :created_time, :amount, :bank, :card_brand, :payout_requisite, :raw_data

    def initialize(data)
      @raw_data = data
      @operation_id = data['operation_id'].to_s
      @created_at = data['created_at'].to_s
      @created_time = Time.iso8601(@created_at)
      @amount = data['amount'].to_f
      @bank = data['bank'].to_s
      @card_brand = data['card_brand']
      @payout_requisite = data['payout_requisite'] || {}
    end

    def sbp_phone
      payout_requisite.dig('sbp', 'phone')
    end

    def sbp_bank_name
      payout_requisite.dig('sbp', 'bank_name')
    end

    def to_h
      @raw_data
    end
  end
end
