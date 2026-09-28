# frozen_string_literal: true

module PaymentStatus
  PENDING = "PENDING"
  PAID = "PAID"
  FAILED = "FAILED"
  REFUNDED_PARTIAL = "REFUNDED_PARTIAL"
  REFUNDED_FULL = "REFUNDED_FULL"
  VOIDED = "VOIDED"
  # Paid after the order expired / was cancelled: the coffee shop returns the money
  REFUND_REQUIRED = "REFUND_REQUIRED"

  ALL = [PENDING, PAID, FAILED, REFUNDED_PARTIAL, REFUNDED_FULL, VOIDED, REFUND_REQUIRED].freeze

  # Money was actually received for the order (even if it has to be / was refunded)
  SETTLED = [PAID, REFUNDED_PARTIAL, REFUNDED_FULL, REFUND_REQUIRED].freeze
end
