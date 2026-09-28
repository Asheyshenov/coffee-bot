# frozen_string_literal: true

# Payment Model
# Tracks payment information from QRPay

require_relative '../../config/boot'
require_relative 'order_status'
require 'bigdecimal'

class Payment < Sequel::Model
  many_to_one :order
  one_to_many :payment_operations

  # Parse an amount reported by a provider (tyiyn, same unit as orders.total_amount).
  # Accepts Integer, Float/BigDecimal and numeric strings: "15000", "15000.00", "15 000,00".
  #
  # @param value [Integer, Numeric, String, nil] Raw amount
  # @return [BigDecimal, nil] nil when no amount was reported
  # @raise [ArgumentError] when an amount is present but not a finite number
  def self.parse_amount(value)
    return nil if value.nil?
    return BigDecimal(value) if value.is_a?(Integer)

    str = value.to_s.strip.delete(' ').tr(',', '.')
    return nil if str.empty?

    amount = BigDecimal(str)
    raise ArgumentError, "invalid amount: #{value.inspect}" unless amount.finite?

    amount
  rescue TypeError
    raise ArgumentError, "invalid amount: #{value.inspect}"
  end

  # Validations
  def validate
    super
    errors.add(:order_id, 'cannot be nil') if order_id.nil?
    errors.add(:status, 'is invalid') unless PaymentStatus::ALL.include?(status)
  end

  # Scopes
  dataset_module do
    def paid
      where(status: PaymentStatus::PAID)
    end

    def pending
      where(status: PaymentStatus::PENDING)
    end

    def by_invoice_id(invoice_id)
      where(invoice_id_provider: invoice_id).first
    end
  end

  # Instance methods

  # Check if payment is refundable
  def refundable?
    status == PaymentStatus::PAID
  end

  # Calculate total refunded amount
  def total_refunded
    payment_operations
      .where(operation_type: PaymentOperationType::REFUND, status: PaymentOperationStatus::COMPLETED)
      .sum(:amount) || 0
  end

  # Calculate remaining refundable amount
  def remaining_refundable
    (paid_amount || 0) - total_refunded
  end

  # Check if can refund specific amount
  def can_refund?(amount)
    refundable? && amount <= remaining_refundable && amount > 0
  end

  # Check if fully refunded
  def fully_refunded?
    total_refunded >= (paid_amount || 0)
  end

  # Update status based on refunds
  def update_refund_status!
    if fully_refunded?
      update(status: PaymentStatus::REFUNDED_FULL)
    elsif total_refunded > 0
      update(status: PaymentStatus::REFUNDED_PARTIAL)
    end
  end

  # Format for display
  def formatted_paid_amount
    return 'N/A' unless paid_amount
    kgs = paid_amount.to_f / 100
    format('%.2f KGS', kgs)
  end
end
