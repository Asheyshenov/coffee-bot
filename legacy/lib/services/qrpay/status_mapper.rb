# frozen_string_literal: true

# QRPay Status Mapper
# Maps provider status codes to internal status values

module QRPay
  class StatusMapper
    # Provider status codes from O!Деньги QRPay API
    # These are example statuses - adjust based on actual API documentation
    PROVIDER_STATUSES = {
      # Invoice is pending payment
      'PENDING' => :pending,
      'NEW' => :pending,
      'CREATED' => :pending,
      'WAITING' => :pending,
      
      # Payment completed successfully
      'PAID' => :paid,
      'COMPLETED' => :paid,
      'SUCCESS' => :paid,
      
      # Invoice cancelled
      'CANCELLED' => :cancelled,
      'CANCELED' => :cancelled,
      'CANCEL' => :cancelled,
      
      # Invoice expired
      'EXPIRED' => :expired,
      'TIMEOUT' => :expired,
      
      # Payment failed
      'FAILED' => :failed,
      'ERROR' => :failed,
      
      # Partially refunded
      'PARTIAL_REFUND' => :refunded_partial,
      'PARTIALLY_REFUNDED' => :refunded_partial,
      
      # Fully refunded
      'REFUNDED' => :refunded_full,
      'FULL_REFUND' => :refunded_full,
      
      # Voided
      'VOIDED' => :voided,
      'VOID' => :voided
    }.freeze

    # Internal status mapping
    INTERNAL_STATUS_MAP = {
      pending: 'PENDING',
      paid: 'PAID',
      cancelled: 'CANCELLED',
      expired: 'EXPIRED',
      failed: 'FAILED',
      refunded_partial: 'REFUNDED_PARTIAL',
      refunded_full: 'REFUNDED_FULL',
      voided: 'VOIDED'
    }.freeze

    # Map provider status to internal status
    #
    # @param provider_status [String] The status from QRPay
    # @return [Symbol] Internal status symbol
    def self.map_from_provider(provider_status)
      return :unknown if provider_status.nil?
      
      normalized = provider_status.to_s.upcase.strip
      PROVIDER_STATUSES[normalized] || :unknown
    end

    # Map internal status to provider status
    #
    # @param internal_status [Symbol] Internal status symbol
    # @return [String] Provider status string
    def self.map_to_provider(internal_status)
      INTERNAL_STATUS_MAP[internal_status.to_sym] || 'UNKNOWN'
    end

    # Check if status indicates payment is complete
    def self.paid?(provider_status)
      map_from_provider(provider_status) == :paid
    end

    # Check if status indicates invoice can be cancelled
    def self.cancellable?(provider_status)
      %i[pending].include?(map_from_provider(provider_status))
    end

    # Check if status indicates invoice is terminal (no further changes)
    def self.terminal?(provider_status)
      %i[paid cancelled expired failed refunded_full voided].include?(map_from_provider(provider_status))
    end

    # Get all statuses that indicate payment received
    def self.payment_received_statuses
      %i[paid refunded_partial refunded_full voided]
    end

    # Get display name for status
    def self.display_name(status)
      case status.to_sym
      when :pending
        'Ожидает оплату'
      when :paid
        'Оплачен'
      when :cancelled
        'Отменён'
      when :expired
        'Истёк'
      when :failed
        'Ошибка'
      when :refunded_partial
        'Частичный возврат'
      when :refunded_full
        'Полный возврат'
      when :voided
        'Отменён'
      else
        status.to_s
      end
    end
  end
end
