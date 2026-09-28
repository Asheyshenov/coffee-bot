# frozen_string_literal: true

require "bigdecimal"

# The payment record of an order (one per order): paid, failed, refund required / refunded
class Payment < ApplicationRecord
  acts_as_tenant :tenant

  belongs_to :order
  # payment_operations reference the order, not the payment
  has_many :payment_operations, primary_key: :order_id, foreign_key: :order_id, inverse_of: false

  validates :status, inclusion: { in: PaymentStatus::ALL }

  scope :settled, -> { where(status: PaymentStatus::SETTLED) }

  # Parse an amount reported by a provider (tyiyn, same unit as orders.total_amount).
  # Accepts Integer, Float/BigDecimal and numeric strings: "15000", "15000.00", "15 000,00".
  #
  # @return [BigDecimal, nil] nil when no amount was reported
  # @raise [ArgumentError] when an amount is present but not a finite number
  def self.parse_amount(value)
    return nil if value.nil?
    return BigDecimal(value) if value.is_a?(Integer)

    str = value.to_s.strip.delete(" ").tr(",", ".")
    return nil if str.empty?

    amount = BigDecimal(str)
    raise ArgumentError, "invalid amount: #{value.inspect}" unless amount.finite?

    amount
  rescue TypeError
    raise ArgumentError, "invalid amount: #{value.inspect}"
  end

  def refundable? = status == PaymentStatus::PAID

  def total_refunded
    payment_operations.where(operation_type: PaymentOperationType::REFUND, status: PaymentOperationStatus::COMPLETED)
                      .sum(:amount)
  end

  def remaining_refundable = (paid_amount || 0) - total_refunded
  def can_refund?(amount) = refundable? && amount.positive? && amount <= remaining_refundable
  def fully_refunded? = total_refunded >= (paid_amount || 0)
end
