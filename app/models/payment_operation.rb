# frozen_string_literal: true

# Audit trail of refunds and voids
class PaymentOperation < ApplicationRecord
  acts_as_tenant :tenant

  belongs_to :order

  validates :operation_type, inclusion: { in: PaymentOperationType::ALL }
  validates :status, inclusion: { in: PaymentOperationStatus::ALL }
  validates :amount, numericality: { only_integer: true, greater_than: 0 }

  scope :refunds, -> { where(operation_type: PaymentOperationType::REFUND) }
  scope :completed, -> { where(status: PaymentOperationStatus::COMPLETED) }
end
