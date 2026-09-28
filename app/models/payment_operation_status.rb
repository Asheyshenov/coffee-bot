# frozen_string_literal: true

module PaymentOperationStatus
  PENDING = "PENDING"
  COMPLETED = "COMPLETED"
  FAILED = "FAILED"

  ALL = [ PENDING, COMPLETED, FAILED ].freeze
end
