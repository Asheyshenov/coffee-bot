# frozen_string_literal: true

# Order Model
# Main model for tracking orders throughout their lifecycle
# Includes state machine for status transitions

require_relative '../../config/boot'
require_relative 'order_status'
require_relative 'payment'
require 'securerandom'

class Order < Sequel::Model
  one_to_many :order_items
  one_to_one :payment

  # Validations
  def validate
    super
    errors.add(:telegram_user_id, 'cannot be nil') if telegram_user_id.nil?
    errors.add(:status, 'is invalid') unless OrderStatus::ALL.include?(status)
    errors.add(:total_amount, 'must be positive') if total_amount.nil? || total_amount <= 0
  end

  # Scopes
  dataset_module do
    def for_user(telegram_user_id)
      where(telegram_user_id: telegram_user_id).order(Sequel.desc(:created_at))
    end

    def with_status(status)
      where(status: status).order(:created_at)
    end

    def paid
      where(status: OrderStatus::PAID).order(:created_at)
    end

    def in_progress
      where(status: OrderStatus::IN_PROGRESS).order(:created_at)
    end

    def invoice_created
      where(status: OrderStatus::INVOICE_CREATED)
    end

    def expirable(expire_minutes)
      where(
        status: OrderStatus::INVOICE_CREATED,
        created_at: (Time.now.utc - (expire_minutes * 60))..Time.now.utc
      )
    end

    def active
      where(status: OrderStatus::ACTIVE).order(:created_at)
    end

    def ready_for_barista
      where(status: OrderStatus::BARISTA_VISIBLE).order(:created_at)
    end

    def for_barista(barista_id)
      where(assigned_to_barista_id: barista_id, status: OrderStatus::IN_PROGRESS)
    end

    def recent(limit = 10)
      order(Sequel.desc(:created_at)).limit(limit)
    end

    def today
      where(created_at: Date.today..Date.today + 1)
    end
  end

  # Class methods

  # Generate unique merchant invoice ID
  def self.generate_merchant_invoice_id(order_id = nil)
    timestamp = Time.now.utc.strftime('%Y%m%d%H%M%S')
    random = SecureRandom.hex(4).upcase
    "ORDER-#{timestamp}-#{random}"
  end

  # Create order from draft
  # Prices and availability come from the menu at checkout time, not from the cart
  # (the cart may be hours old). Zero-quantity lines are ignored.
  #
  # @return [Order, nil] nil if the cart is empty or has an item that is no longer available
  def self.create_from_draft(draft, client)
    lines = checkout_lines(draft)
    return nil if lines.nil? || lines.empty?

    order = nil

    DB.transaction do
      # Create the order with pre-generated merchant_invoice_id
      order = new(
        telegram_user_id: client.telegram_user_id,
        client_display_name: client.display_name,
        comment: draft.comment,
        status: OrderStatus::NEW,
        total_amount: lines.sum { |line| line[:line_total] },
        currency: 'KGS',
        merchant_invoice_id: generate_merchant_invoice_id
      ).save(raise_on_failure: true)

      # A line that fails validation rolls the whole order back instead of vanishing
      lines.each do |line|
        OrderItem.new(line.merge(order_id: order.id)).save(raise_on_failure: true)
      end

      # Increment client's order count
      client.increment_orders!
    end

    order
  end

  # Order lines priced from the current menu
  #
  # @return [Array<Hash>, nil] nil if an item is missing or unavailable
  def self.checkout_lines(draft)
    return nil unless draft

    draft.items.filter_map do |item|
      qty = item['qty'].to_i
      next unless qty.positive?

      menu_item = MenuItem[item['menu_item_id']]
      return nil unless menu_item&.is_available

      qty = [qty, Draft::MAX_QTY_PER_LINE].min
      unit_price = menu_item.price_for_size(item['size'])
      {
        menu_item_id: menu_item.id,
        item_name: menu_item.display_name_for_size(item['size']),
        size: item['size'],
        qty: qty,
        unit_price: unit_price,
        line_total: unit_price * qty
      }
    end
  end

  # Instance methods

  # Check if status transition is allowed
  def can_transition_to?(new_status)
    OrderStatus.can_transition?(status, new_status)
  end

  # Transition to new status with validation
  def transition_to!(new_status)
    old_status = status
    unless can_transition_to?(new_status)
      raise InvalidStatusTransition, "Cannot transition from #{old_status} to #{new_status}"
    end

    update(status: new_status)
    log_info('Order status changed', order_id: id, from: old_status, to: new_status)
    true
  end

  # Safe transition (returns false instead of raising)
  def transition_to(new_status)
    transition_to!(new_status)
  rescue InvalidStatusTransition
    false
  end

  # Check if order can be claimed by barista
  def claimable?
    status == OrderStatus::PAID && assigned_to_barista_id.nil?
  end

  # Claim order for barista (atomic operation with transaction)
  # Uses SELECT FOR UPDATE to prevent race conditions when multiple
  # baristas try to claim the same order simultaneously
  def claim_for_barista!(barista_id)
    DB.transaction do
      # Lock the row first to prevent concurrent access
      locked_order = self.class.for_update.where(id: id).first
      
      unless locked_order && locked_order.claimable?
        log_info('Order claim failed - not claimable', order_id: id)
        return false
      end

      # Now safe to update - we hold the lock
      locked_order.update(
        status: OrderStatus::IN_PROGRESS,
        assigned_to_barista_id: barista_id,
        assigned_at: Time.now.utc
      )
      
      log_info('Order claimed', order_id: id, barista_id: barista_id)
      true
    end
  end

  # Class method: Claim next available order atomically
  # Use this for "take next order" functionality
  def self.claim_next_for_barista!(barista_id)
    DB.transaction do
      # Lock the first available order
      order = for_update
        .where(status: OrderStatus::PAID, assigned_to_barista_id: nil)
        .order(:created_at)
        .first
      
      return nil unless order

      order.update(
        status: OrderStatus::IN_PROGRESS,
        assigned_to_barista_id: barista_id,
        assigned_at: Time.now.utc
      )
      
      order.log_info('Order claimed (next available)', order_id: order.id, barista_id: barista_id)
      order
    end
  end

  # Mark order as ready
  def mark_ready!
    return false unless status == OrderStatus::IN_PROGRESS

    update(status: OrderStatus::READY)
    log_info('Order marked as ready', order_id: id)
    true
  end

  # Cancel order
  def cancel!(reason = nil)
    return false unless [OrderStatus::PAID, OrderStatus::IN_PROGRESS].include?(status)

    update(status: OrderStatus::CANCELLED)
    log_info('Order cancelled', order_id: id, reason: reason)
    true
  end

  # Mark as expired
  # Conditional UPDATE: a payment that lands concurrently (PAID) is never overwritten
  def expire!
    return false unless status == OrderStatus::INVOICE_CREATED

    expired = self.class.where(id: id, status: OrderStatus::INVOICE_CREATED)
                        .update(status: OrderStatus::EXPIRED, updated_at: Time.now.utc)
    refresh
    return false unless expired == 1

    log_info('Order expired', order_id: id)
    true
  end

  # Set invoice data from payment provider (QRPay or MWallet)
  def set_invoice_data(invoice_data)
    update(
      invoice_id_provider: invoice_data[:invoice_id],
      qr_payload: invoice_data[:qr_payload] || invoice_data[:emv_qr_data],
      qr_url: invoice_data[:qr_url] || invoice_data[:paylink_url],
      emv_qr_url: invoice_data[:emv_qr_url],  # URL to QR image from MWallet
      qr_image_base64: invoice_data[:qr_image_base64],
      expires_at: invoice_data[:expires_at],
      raw_create_response: invoice_data[:raw_response]
    )
  end

  # Mark as paid (atomic)
  # A conditional UPDATE (WHERE status = INVOICE_CREATED) guarantees exactly one winner
  # when callback, StatusSyncer and expirer race; only the winner gets true and only
  # the winner's caller may send notifications.
  #
  # @param payment_data [Hash] :paid_amount, :paid_at, :raw_response
  # @return [Boolean] True only if this call moved the order to PAID
  def mark_paid!(payment_data = {})
    paid_amount = amount_to_integer(payment_data[:paid_amount]) || total_amount
    previous_status = nil

    DB.transaction do
      previous_status = atomic_status_change!([OrderStatus::INVOICE_CREATED], OrderStatus::PAID)

      if previous_status
        save_payment_record!(
          status: PaymentStatus::PAID,
          paid_amount: paid_amount,
          paid_at: payment_data[:paid_at] || Time.now.utc,
          raw_status_response: payment_details_json(payment_data[:raw_response], previous_status: previous_status)
        )
      end
    end

    return false unless previous_status

    refresh
    log_info('Order status changed', order_id: id, from: previous_status, to: OrderStatus::PAID)
    log_info('Order paid', order_id: id, paid_amount: paid_amount)
    true
  end

  # Record a payment that arrived after the order EXPIRED / was CANCELLED (atomic)
  # The order is not fulfilled and keeps its status; the payment is stored as
  # REFUND_REQUIRED so staff return the money. Only one caller wins, so the refund
  # is requested exactly once and late-payment polling stops (settled payment).
  #
  # @param paid_amount [Integer, nil] Amount paid in tyiyn (nil -> order total)
  # @param paid_at [Time, nil] When the provider confirmed the payment
  # @param raw_response [Hash, nil] Provider data for audit
  # @return [String, nil] Order status at the time of payment for the winner, nil otherwise
  def record_late_payment!(paid_amount: nil, paid_at: nil, raw_response: nil)
    previous_status = nil
    settled_payment = Payment.where(order_id: id, status: PaymentStatus::SETTLED)

    DB.transaction do
      current = self.class.for_update.where(id: id).get(:status)
      next unless OrderStatus::LATE_PAYMENT.include?(current)

      claimed = self.class.where(id: id, status: current)
                          .exclude(settled_payment.exists)
                          .update(invoice_status_raw: PaymentStatus::REFUND_REQUIRED, updated_at: Time.now.utc)
      next unless claimed == 1

      previous_status = current
      save_payment_record!(
        status: PaymentStatus::REFUND_REQUIRED,
        paid_amount: amount_to_integer(paid_amount) || total_amount,
        paid_at: paid_at || Time.now.utc,
        raw_status_response: payment_details_json(raw_response, previous_status: current, refund_required: true)
      )
    end

    return nil unless previous_status

    refresh
    log_info('Late payment recorded, refund required', order_id: id, status: previous_status)
    previous_status
  end

  # True if a late payment for this order is waiting to be refunded
  def refund_required?
    Payment.where(order_id: id, status: PaymentStatus::REFUND_REQUIRED).any?
  end

  # Mark a REFUND_REQUIRED payment as returned to the client (atomic)
  #
  # @param staff_id [Integer] Telegram ID of the barista who made the refund
  # @return [Boolean] True only for the call that actually closed the refund
  def mark_refunded!(staff_id)
    refunded = false

    DB.transaction do
      payment = Payment.for_update.where(order_id: id, status: PaymentStatus::REFUND_REQUIRED).first
      next unless payment

      closed = Payment.where(id: payment.id, status: PaymentStatus::REFUND_REQUIRED)
                      .update(status: PaymentStatus::REFUNDED_FULL, updated_at: Time.now.utc)
      next unless closed == 1

      # Audit trail: who returned how much
      PaymentOperation.new(
        order_id: id,
        operation_type: PaymentOperationType::REFUND,
        amount: payment.paid_amount || total_amount,
        status: PaymentOperationStatus::COMPLETED,
        reason: "Late payment refunded manually by staff #{staff_id}"
      ).save(raise_on_failure: true)
      this.update(invoice_status_raw: PaymentStatus::REFUNDED_FULL, updated_at: Time.now.utc)
      refunded = true
    end
    return false unless refunded

    refresh
    log_info('Late payment refunded', order_id: id, staff_id: staff_id)
    true
  end

  # Move order to ERROR because the provider reported a payment we must not accept
  # (e.g. paid amount below the total). Atomic like mark_paid!, so the problem is
  # reported exactly once and polling stops (ERROR is terminal).
  #
  # @param reason [String] Short explanation stored in invoice_status_raw
  # @param paid_amount [Integer, nil] Amount actually paid (tyiyn)
  # @param raw_response [Hash, nil] Provider data for audit
  # @return [Boolean] True only if this call moved the order to ERROR
  def mark_payment_error!(reason:, paid_amount: nil, raw_response: nil)
    previous_status = nil

    DB.transaction do
      previous_status = atomic_status_change!(
        [OrderStatus::INVOICE_CREATED], OrderStatus::ERROR, invoice_status_raw: reason.to_s[0, 255]
      )

      if previous_status
        save_payment_record!(
          status: PaymentStatus::FAILED,
          paid_amount: amount_to_integer(paid_amount),
          raw_status_response: payment_details_json(raw_response, previous_status: previous_status, error: reason)
        )
      end
    end

    return false unless previous_status

    refresh
    log_info('Order status changed', order_id: id, from: previous_status, to: OrderStatus::ERROR)
    true
  end

  # Check if invoice is expired
  def invoice_expired?
    return false unless expires_at
    Time.now.utc > expires_at
  end

  # Format order for display
  def format_for_client
    lines = []
    lines << "☕ Заказ ##{id}"
    lines << "Статус: #{OrderStatus.display_name(status)}"
    lines << ''
    lines << 'Позиции:'
    
    order_items.each do |item|
      total_kgs = item.line_total.to_i / 100
      lines << "  • #{item.item_name} x#{item.qty} = #{total_kgs} KGS"
    end
    
    lines << ''
    lines << "Итого: #{formatted_total}"
    
    if comment
      lines << ''
      lines << "Комментарий: #{comment}"
    end
    
    lines.join("\n")
  end

  # Format order for barista
  def format_for_barista
    lines = []
    lines << "━━━━━━━━━━━━━━━━━━━━━━"
    lines << "☕ Заказ ##{id}"
    lines << "🕐 #{created_at.strftime('%H:%M')}"
    lines << "👤 #{client_display_name}"
    lines << ''
    lines << 'Позиции:'
    
    order_items.each do |item|
      lines << "  • #{item.item_name} x#{item.qty}"
    end
    
    lines << ''
    lines << "💰 #{formatted_total}"
    
    if comment
      lines << ''
      lines << "📝 #{comment}"
    end
    
    lines << "━━━━━━━━━━━━━━━━━━━━━━"
    lines.join("\n")
  end

  # Format total for display
  def formatted_total
    kgs = total_amount.to_i / 100
    format('%d KGS', kgs)
  end

  # Display status
  def display_status
    OrderStatus.display_name(status)
  end

  # Format short summary for active order notification
  # Returns something like "Капучино L x2, Чизкейк x1"
  def format_short_summary
    order_items.map do |item|
      "#{item.item_name} x#{item.qty}"
    end.join(', ')
  end

  private

  # Conditional UPDATE: changes status only if the row is still in one of
  # from_statuses and has no settled payment yet (a paid-then-cancelled order is
  # never resurrected). Must run inside a transaction.
  #
  # @return [String, nil] Previous status for the winner, nil if nothing changed
  def atomic_status_change!(from_statuses, to_status, extra_columns = {})
    allowed = from_statuses.select { |s| OrderStatus.can_transition?(s, to_status) }
    settled_payment = Payment.where(order_id: id, status: PaymentStatus::SETTLED)

    # Second attempt covers a status change between the read and the UPDATE
    # (e.g. expirer moved INVOICE_CREATED -> EXPIRED); on PostgreSQL the row lock prevents it
    2.times do
      current = self.class.for_update.where(id: id).get(:status)
      return nil unless allowed.include?(current)

      changed = self.class.where(id: id, status: current)
                          .exclude(settled_payment.exists)
                          .update(extra_columns.merge(status: to_status, updated_at: Time.now.utc))
      return current if changed == 1
    end

    nil
  end

  # Create or update the payment record (inside the caller's transaction)
  def save_payment_record!(attrs)
    attrs = attrs.merge(invoice_id_provider: invoice_id_provider)
    record = Payment.for_update.where(order_id: id).order(:id).first

    if record
      record.set(attrs).save(raise_on_failure: true)
    else
      Payment.new(attrs.merge(order_id: id)).save(raise_on_failure: true)
    end
  end

  # Provider data for audit, without the signature
  def payment_details_json(raw_response, extra = {})
    raw = raw_response.is_a?(Hash) ? raw_response.reject { |k, _| k.to_s == 'hash' } : raw_response
    { provider: raw, **extra }.to_json
  end

  # Provider amount -> Integer tyiyn (nil when missing or unparseable)
  def amount_to_integer(value)
    Payment.parse_amount(value)&.to_i
  rescue ArgumentError
    nil
  end
end

# Custom exception for invalid status transitions
class InvalidStatusTransition < StandardError; end
