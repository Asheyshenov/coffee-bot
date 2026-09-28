# frozen_string_literal: true

module MWallet
  # Maps MWallet payment statuses to internal symbols
  class StatusMapper
    PENDING = 1          # В ожидании
    CANCELLED = 2        # Аннулирован
    SUCCESS = 3          # Успешный
    PENDING_DEBIT = 4    # Средства списаны, но оплата не завершена (в ожидании)
    PARTIAL_REFUND = 6   # Частичный возврат
    PENDING_VERIFY = 8   # Ожидание проверки списания средств
    PENDING_ALT = 9      # В ожидании (альтернативный код)

    # The format depends on the merchant: some return text ("approved", "processing"),
    # others numeric codes, as Integer (3) or as String ("3", e.g. form-encoded callbacks)
    #
    # @param status [Integer, String, nil]
    # @return [Symbol] :paid, :cancelled, :pending, :partial_refund or :unknown
    def self.map_from_provider(status)
      return :unknown if status.nil?

      if status.is_a?(String)
        return map_from_string_status(status) unless status.strip.match?(/\A\d+\z/)

        status = status.strip.to_i
      end
      # 3.0 is still code 3; anything else (hashes, 3.5) is not a status
      return :unknown unless status.is_a?(Numeric) && status == status.to_i

      case status.to_i
      when SUCCESS then :paid
      when CANCELLED then :cancelled
      when PENDING, PENDING_DEBIT, PENDING_VERIFY, PENDING_ALT then :pending
      when PARTIAL_REFUND then :partial_refund
      else :unknown
      end
    end

    # @param status [String]
    # @return [Symbol]
    def self.map_from_string_status(status)
      case status.downcase.strip
      when "approved", "success", "completed", "paid" then :paid
      when "cancelled", "canceled", "expired", "rejected" then :cancelled
      when "wait", "pending", "processing", "created" then :pending
      else :unknown
      end
    end

    # No more changes expected
    def self.final_status?(status) = [ SUCCESS, CANCELLED, PARTIAL_REFUND ].include?(status.to_i)

    def self.paid?(status) = status.to_i == SUCCESS

    def self.pending?(status) = [ PENDING, PENDING_DEBIT, PENDING_VERIFY, PENDING_ALT ].include?(status.to_i)

    # @return [String] status description in Russian
    def self.description(status)
      case status.to_i
      when PENDING, PENDING_ALT then "В ожидании"
      when CANCELLED then "Аннулирован"
      when SUCCESS then "Успешный"
      when PENDING_DEBIT then "Средства списаны, оплата в ожидании"
      when PARTIAL_REFUND then "Частичный возврат"
      when PENDING_VERIFY then "Ожидание проверки списания"
      else "Неизвестный статус"
      end
    end
  end
end
