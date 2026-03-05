# frozen_string_literal: true

# Order Status Constants and State Machine
# Defines all valid statuses and allowed transitions

module OrderStatus
  # Order has been created but invoice not yet generated
  NEW = 'NEW'
  
  # Invoice created in QRPay, waiting for payment
  INVOICE_CREATED = 'INVOICE_CREATED'
  
  # Payment received, order is in queue
  PAID = 'PAID'
  
  # Barista has claimed the order and is preparing it
  IN_PROGRESS = 'IN_PROGRESS'
  
  # Order is ready for pickup
  READY = 'READY'
  
  # Order was cancelled
  CANCELLED = 'CANCELLED'
  
  # Invoice expired without payment
  EXPIRED = 'EXPIRED'
  
  # An error occurred during processing
  ERROR = 'ERROR'

  # All valid statuses
  ALL = [NEW, INVOICE_CREATED, PAID, IN_PROGRESS, READY, CANCELLED, EXPIRED, ERROR].freeze
  
  # Statuses visible to barista (only paid orders)
  BARISTA_VISIBLE = [PAID].freeze
  
  # Statuses that can be claimed by barista
  CLAIMABLE = [PAID].freeze
  
  # Active statuses (order is being processed)
  ACTIVE = [INVOICE_CREATED, PAID, IN_PROGRESS].freeze
  
  # Terminal statuses (order is complete)
  TERMINAL = [READY, CANCELLED, EXPIRED].freeze

  # Allowed status transitions
  # Format: { from_status => [allowed_to_statuses] }
  TRANSITIONS = {
    NEW => [INVOICE_CREATED, ERROR],
    INVOICE_CREATED => [PAID, EXPIRED, CANCELLED, ERROR],
    PAID => [IN_PROGRESS, CANCELLED],
    IN_PROGRESS => [READY, CANCELLED],
    READY => [],
    CANCELLED => [],
    EXPIRED => [],
    ERROR => []
  }.freeze

  # Check if transition is allowed
  def self.can_transition?(from_status, to_status)
    allowed = TRANSITIONS[from_status]
    allowed&.include?(to_status) || false
  end

  # Get allowed transitions from a status
  def self.allowed_transitions(from_status)
    TRANSITIONS[from_status] || []
  end

  # Check if status is terminal (no further transitions)
  def self.terminal?(status)
    TERMINAL.include?(status)
  end

  # Check if status is active (order in progress)
  def self.active?(status)
    ACTIVE.include?(status)
  end

  # Human-readable status names in Russian
  DISPLAY_NAMES = {
    NEW => 'Новый',
    INVOICE_CREATED => 'Ожидает оплату',
    PAID => 'Оплачен',
    IN_PROGRESS => 'Готовится',
    READY => 'Готов',
    CANCELLED => 'Отменён',
    EXPIRED => 'Истёк',
    ERROR => 'Ошибка'
  }.freeze

  def self.display_name(status)
    DISPLAY_NAMES[status] || status
  end
end

# Payment Status Constants
module PaymentStatus
  PENDING = 'PENDING'
  PAID = 'PAID'
  FAILED = 'FAILED'
  REFUNDED_PARTIAL = 'REFUNDED_PARTIAL'
  REFUNDED_FULL = 'REFUNDED_FULL'
  VOIDED = 'VOIDED'

  ALL = [PENDING, PAID, FAILED, REFUNDED_PARTIAL, REFUNDED_FULL, VOIDED].freeze
end

# Payment Operation Types
module PaymentOperationType
  REFUND = 'REFUND'
  VOID = 'VOID'

  ALL = [REFUND, VOID].freeze
end

# Payment Operation Status
module PaymentOperationStatus
  PENDING = 'PENDING'
  COMPLETED = 'COMPLETED'
  FAILED = 'FAILED'

  ALL = [PENDING, COMPLETED, FAILED].freeze
end
