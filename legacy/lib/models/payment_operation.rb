# frozen_string_literal: true

# PaymentOperation Model
# Journal of refund and void operations for audit trail

require_relative '../../config/boot'
require_relative 'order_status'

class PaymentOperation < Sequel::Model
  many_to_one :order

  # Validations
  def validate
    super
    errors.add(:order_id, 'cannot be nil') if order_id.nil?
    errors.add(:operation_type, 'is invalid') unless PaymentOperationType::ALL.include?(operation_type)
    errors.add(:status, 'is invalid') unless PaymentOperationStatus::ALL.include?(status)
    errors.add(:amount, 'must be positive') if amount.nil? || amount <= 0
  end

  # Scopes
  dataset_module do
    def refunds
      where(operation_type: PaymentOperationType::REFUND)
    end

    def voids
      where(operation_type: PaymentOperationType::VOID)
    end

    def completed
      where(status: PaymentOperationStatus::COMPLETED)
    end

    def pending
      where(status: PaymentOperationStatus::PENDING)
    end
  end

  # Instance methods

  # Mark as completed
  def complete!(provider_id = nil)
    update(
      status: PaymentOperationStatus::COMPLETED,
      operation_id_provider: provider_id
    )
  end

  # Mark as failed
  def fail!(error_message = nil)
    update(
      status: PaymentOperationStatus::FAILED,
      raw_response: error_message
    )
  end

  # Format for display
  def formatted_amount
    kgs = amount.to_f / 100
    format('%.2f KGS', kgs)
  end

  # Display type
  def display_type
    case operation_type
    when PaymentOperationType::REFUND
      'Возврат'
    when PaymentOperationType::VOID
      'Отмена'
    else
      operation_type
    end
  end
end
