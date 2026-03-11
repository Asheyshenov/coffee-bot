# frozen_string_literal: true

# MWallet Status Mapper
# Maps mwallet status codes to internal order statuses

module MWallet
  class StatusMapper
    # MWallet status codes
    PENDING = 1          # В ожидании
    CANCELLED = 2        # Аннулирован
    SUCCESS = 3          # Успешный
    PENDING_DEBIT = 4    # Средства списаны, но оплата не завершена (в ожидании)
    PARTIAL_REFUND = 6   # Частичный возврат
    PENDING_VERIFY = 8   # Ожидание проверки списания средств
    PENDING_ALT = 9      # В ожидании (альтернативный код)

    # Map mwallet status to internal status symbol
    #
    # @param status [Integer, String] MWallet status code (numeric or string)
    # @return [Symbol] Internal status symbol
    def self.map_from_provider(status)
      # Handle string status values from statusPayment API
      if status.is_a?(String)
        case status.downcase
        when 'success'
          return :paid
        when 'cancel', 'cancelled'
          return :cancelled
        when 'wait', 'pending'
          return :pending
        end
      end

      # Handle numeric status codes
      code = status.to_i

      case code
      when SUCCESS
        :paid
      when CANCELLED
        :cancelled
      when PENDING, PENDING_DEBIT, PENDING_VERIFY, PENDING_ALT
        :pending
      when PARTIAL_REFUND
        :partial_refund
      else
        :unknown
      end
    end

    # Check if status is final (no more changes expected)
    #
    # @param status [Integer, String] MWallet status code
    # @return [Boolean] True if status is final
    def self.final_status?(status)
      code = status.to_i

      [SUCCESS, CANCELLED, PARTIAL_REFUND].include?(code)
    end

    # Check if status indicates successful payment
    #
    # @param status [Integer, String] MWallet status code
    # @return [Boolean] True if payment is successful
    def self.paid?(status)
      status.to_i == SUCCESS
    end

    # Check if status is pending
    #
    # @param status [Integer, String] MWallet status code
    # @return [Boolean] True if status is pending
    def self.pending?(status)
      code = status.to_i

      [PENDING, PENDING_DEBIT, PENDING_VERIFY, PENDING_ALT].include?(code)
    end

    # Get human-readable status description
    #
    # @param status [Integer, String] MWallet status code
    # @return [String] Status description in Russian
    def self.description(status)
      code = status.to_i

      case code
      when PENDING, PENDING_ALT
        'В ожидании'
      when CANCELLED
        'Аннулирован'
      when SUCCESS
        'Успешный'
      when PENDING_DEBIT
        'Средства списаны, оплата в ожидании'
      when PARTIAL_REFUND
        'Частичный возврат'
      when PENDING_VERIFY
        'Ожидание проверки списания'
      else
        'Неизвестный статус'
      end
    end
  end
end
