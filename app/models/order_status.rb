# frozen_string_literal: true

# Order statuses and allowed transitions (also enforced by the orders_status_check constraint)
module OrderStatus
  # Order has been created but invoice not yet generated
  NEW = "NEW"
  # Invoice created at the payment provider, waiting for payment
  INVOICE_CREATED = "INVOICE_CREATED"
  # Payment received, order is in the barista queue
  PAID = "PAID"
  # Barista has claimed the order and is preparing it
  IN_PROGRESS = "IN_PROGRESS"
  # Order is ready for pickup
  READY = "READY"
  CANCELLED = "CANCELLED"
  # Invoice expired without payment
  EXPIRED = "EXPIRED"
  # Invoice could not be created, or a payment could not be accepted
  ERROR = "ERROR"

  ALL = [ NEW, INVOICE_CREATED, PAID, IN_PROGRESS, READY, CANCELLED, EXPIRED, ERROR ].freeze

  # Statuses visible to baristas (only paid orders)
  BARISTA_VISIBLE = [ PAID ].freeze
  ACTIVE = [ INVOICE_CREATED, PAID, IN_PROGRESS ].freeze
  TERMINAL = [ READY, CANCELLED, EXPIRED ].freeze

  # Late payment: the customer was charged after the invoice expired / the order was
  # cancelled (e.g. invoiceCancel failed and the QR stayed payable). The order is NOT
  # fulfilled: it keeps its status and the payment is recorded as REFUND_REQUIRED.
  LATE_PAYMENT = [ EXPIRED, CANCELLED ].freeze

  TRANSITIONS = {
    NEW => [ INVOICE_CREATED, ERROR ],
    INVOICE_CREATED => [ PAID, EXPIRED, CANCELLED, ERROR ],
    PAID => [ IN_PROGRESS, CANCELLED ],
    IN_PROGRESS => [ READY, CANCELLED ],
    READY => [],
    CANCELLED => [],
    EXPIRED => [],
    ERROR => []
  }.freeze

  DISPLAY_NAMES = {
    NEW => "Новый",
    INVOICE_CREATED => "Ожидает оплату",
    PAID => "Оплачен",
    IN_PROGRESS => "Готовится",
    READY => "Готов",
    CANCELLED => "Отменён",
    EXPIRED => "Истёк",
    ERROR => "Ошибка"
  }.freeze

  def self.can_transition?(from_status, to_status)
    TRANSITIONS.fetch(from_status, []).include?(to_status)
  end

  def self.allowed_transitions(from_status) = TRANSITIONS.fetch(from_status, [])
  def self.terminal?(status) = TERMINAL.include?(status)
  def self.active?(status) = ACTIVE.include?(status)
  def self.display_name(status) = DISPLAY_NAMES[status] || status
end
