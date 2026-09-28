# frozen_string_literal: true

require "securerandom"

# An order of a customer in a coffee shop, from invoice to pickup.
#
# Status changes that can race (payment callback vs polling vs expiry vs a barista)
# are conditional UPDATEs (WHERE status = ...): exactly one caller wins, and only the
# winner sends notifications.
class Order < ApplicationRecord
  class InvalidStatusTransition < StandardError; end

  acts_as_tenant :tenant

  belongs_to :customer
  belongs_to :payment_account, optional: true
  has_many :order_items, -> { order(:id) }, dependent: :destroy, inverse_of: :order
  has_one :payment, dependent: :destroy
  has_many :payment_operations, dependent: :destroy

  validates :status, inclusion: { in: OrderStatus::ALL }
  validates :total_amount, numericality: { only_integer: true, greater_than: 0 }
  validates :telegram_user_id, :client_display_name, :merchant_invoice_id, presence: true
  validates :comment, length: { maximum: Draft::COMMENT_MAX_LENGTH }, allow_nil: true

  scope :for_user, ->(telegram_user_id) { where(telegram_user_id: telegram_user_id).order(created_at: :desc) }
  scope :active, -> { where(status: OrderStatus::ACTIVE).order(:created_at) }
  scope :ready_for_barista, -> { where(status: OrderStatus::BARISTA_VISIBLE).order(:created_at) }
  scope :for_barista, ->(barista_id) { where(assigned_to_barista_id: barista_id, status: OrderStatus::IN_PROGRESS) }
  scope :recent, ->(limit = 10) { order(created_at: :desc).limit(limit) }

  def self.generate_merchant_invoice_id
    "ORDER-#{Time.now.utc.strftime('%Y%m%d%H%M%S')}-#{SecureRandom.hex(4).upcase}"
  end

  # Create an order from the customer's cart.
  # Prices and availability come from the menu at checkout time, not from the cart
  # (the cart may be hours old). Zero-quantity lines are ignored.
  #
  # @return [Order, nil] nil if the cart is empty or has an item that is no longer available
  def self.create_from_draft(draft, customer)
    lines = checkout_lines(draft)
    return nil if lines.blank?

    transaction do
      order = create!(
        customer: customer,
        telegram_user_id: customer.telegram_user_id,
        client_display_name: customer.display_name,
        comment: draft.comment,
        status: OrderStatus::NEW,
        total_amount: lines.sum { |line| line[:line_total] },
        currency: "KGS",
        merchant_invoice_id: generate_merchant_invoice_id
      )
      # A line that fails validation rolls the whole order back instead of vanishing
      lines.each { |line| order.order_items.create!(line) }
      customer.increment_orders!
      order
    end
  end

  # Order lines priced from the current menu
  #
  # @return [Array<Hash>, nil] nil if an item is missing or unavailable
  def self.checkout_lines(draft)
    return nil unless draft

    draft.items.filter_map do |item|
      qty = item["qty"].to_i
      next unless qty.positive?

      menu_item = MenuItem.find_by(id: item["menu_item_id"])
      return nil unless menu_item&.available?

      qty = [qty, Draft::MAX_QTY_PER_LINE].min
      unit_price = menu_item.price_for_size(item["size"])
      {
        menu_item: menu_item,
        item_name: menu_item.display_name_for_size(item["size"]),
        size: item["size"],
        qty: qty,
        unit_price: unit_price,
        line_total: unit_price * qty
      }
    end
  end

  def can_transition_to?(new_status) = OrderStatus.can_transition?(status, new_status)

  # Transition with validation (not for racing paths - use the atomic methods below)
  def transition_to!(new_status)
    old_status = status
    raise InvalidStatusTransition, "Cannot transition from #{old_status} to #{new_status}" unless can_transition_to?(new_status)

    update!(status: new_status)
    AppLog.info("Order status changed", order_id: id, from: old_status, to: new_status)
    true
  end

  def claimable? = status == OrderStatus::PAID && assigned_to_barista_id.nil?

  # Claim a paid order for a barista. Only one barista wins.
  def claim_for_barista!(barista_id)
    claimed = self.class.where(id: id, status: OrderStatus::PAID, assigned_to_barista_id: nil)
                        .update_all(status: OrderStatus::IN_PROGRESS, assigned_to_barista_id: barista_id,
                                    assigned_at: Time.current, updated_at: Time.current)
    reload
    unless claimed == 1
      AppLog.info("Order claim failed - not claimable", order_id: id)
      return false
    end

    AppLog.info("Order claimed", order_id: id, barista_id: barista_id)
    true
  end

  def mark_ready!
    changed = self.class.where(id: id, status: OrderStatus::IN_PROGRESS)
                        .update_all(status: OrderStatus::READY, updated_at: Time.current)
    reload
    return false unless changed == 1

    AppLog.info("Order marked as ready", order_id: id)
    true
  end

  # INVOICE_CREATED -> EXPIRED; a payment that lands concurrently (PAID) is never overwritten
  def expire!
    changed = self.class.where(id: id, status: OrderStatus::INVOICE_CREATED)
                        .update_all(status: OrderStatus::EXPIRED, updated_at: Time.current)
    reload
    return false unless changed == 1

    AppLog.info("Order expired", order_id: id)
    true
  end

  # Cancel an unpaid order locally (NEW / INVOICE_CREATED only)
  def cancel_unpaid!
    changed = self.class.where(id: id, status: [OrderStatus::NEW, OrderStatus::INVOICE_CREATED])
                        .update_all(status: OrderStatus::CANCELLED, updated_at: Time.current)
    reload
    changed == 1
  end

  # Store the invoice data returned by the payment provider
  def set_invoice_data(invoice_data)
    update!(
      invoice_id_provider: invoice_data[:invoice_id],
      qr_payload: invoice_data[:qr_payload] || invoice_data[:emv_qr_data],
      qr_url: invoice_data[:qr_url] || invoice_data[:paylink_url],
      emv_qr_url: invoice_data[:emv_qr_url],
      qr_image_base64: invoice_data[:qr_image_base64],
      expires_at: invoice_data[:expires_at],
      raw_create_response: invoice_data[:raw_response]
    )
  end

  # INVOICE_CREATED -> PAID with the payment record in one transaction
  #
  # @param payment_data [Hash] :paid_amount, :paid_at, :raw_response
  # @return [Boolean] true only if this call moved the order to PAID
  def mark_paid!(payment_data = {})
    paid_amount = amount_to_integer(payment_data[:paid_amount]) || total_amount
    previous_status = nil

    transaction do
      previous_status = atomic_status_change!([OrderStatus::INVOICE_CREATED], OrderStatus::PAID)
      next unless previous_status

      save_payment_record!(
        status: PaymentStatus::PAID,
        paid_amount: paid_amount,
        paid_at: payment_data[:paid_at] || Time.current,
        raw_status_response: payment_details_json(payment_data[:raw_response], previous_status: previous_status)
      )
    end
    return false unless previous_status

    reload
    AppLog.info("Order paid", order_id: id, paid_amount: paid_amount)
    true
  end

  # Record a payment that arrived after the order EXPIRED / was CANCELLED.
  # The order is not fulfilled and keeps its status; the payment is stored as
  # REFUND_REQUIRED so the coffee shop returns the money. Only one caller wins.
  #
  # @return [String, nil] order status at the time of payment for the winner, nil otherwise
  def record_late_payment!(paid_amount: nil, paid_at: nil, raw_response: nil)
    previous_status = nil

    transaction do
      current = self.class.lock.where(id: id).pick(:status)
      next unless OrderStatus::LATE_PAYMENT.include?(current)

      claimed = self.class.where(id: id, status: current)
                          .where(settled_payment_exists.not)
                          .update_all(invoice_status_raw: PaymentStatus::REFUND_REQUIRED, updated_at: Time.current)
      next unless claimed == 1

      previous_status = current
      save_payment_record!(
        status: PaymentStatus::REFUND_REQUIRED,
        paid_amount: amount_to_integer(paid_amount) || total_amount,
        paid_at: paid_at || Time.current,
        raw_status_response: payment_details_json(raw_response, previous_status: current, refund_required: true)
      )
    end
    return nil unless previous_status

    reload
    AppLog.warn("Late payment recorded, refund required", order_id: id, status: previous_status)
    previous_status
  end

  def refund_required? = Payment.exists?(order_id: id, status: PaymentStatus::REFUND_REQUIRED)

  # Close a REFUND_REQUIRED payment once the coffee shop returned the money
  #
  # @param staff_id [Integer] Telegram ID of the staff member who made the refund
  # @return [Boolean] true only for the call that actually closed the refund
  def mark_refunded!(staff_id)
    refunded = false

    transaction do
      payment = Payment.lock.find_by(order_id: id, status: PaymentStatus::REFUND_REQUIRED)
      next unless payment

      payment.update!(status: PaymentStatus::REFUNDED_FULL)
      payment_operations.create!(
        operation_type: PaymentOperationType::REFUND,
        amount: payment.paid_amount || total_amount,
        status: PaymentOperationStatus::COMPLETED,
        reason: "Late payment refunded manually by staff #{staff_id}"
      )
      update_columns(invoice_status_raw: PaymentStatus::REFUNDED_FULL, updated_at: Time.current)
      refunded = true
    end
    return false unless refunded

    reload
    AppLog.info("Late payment refunded", order_id: id, staff_id: staff_id)
    true
  end

  # INVOICE_CREATED -> ERROR for a payment we must not accept (e.g. amount below the total)
  #
  # @return [Boolean] true only if this call moved the order to ERROR
  def mark_payment_error!(reason:, paid_amount: nil, raw_response: nil)
    previous_status = nil

    transaction do
      previous_status = atomic_status_change!([OrderStatus::INVOICE_CREATED], OrderStatus::ERROR,
                                              invoice_status_raw: reason.to_s[0, 255])
      next unless previous_status

      save_payment_record!(
        status: PaymentStatus::FAILED,
        paid_amount: amount_to_integer(paid_amount),
        raw_status_response: payment_details_json(raw_response, previous_status: previous_status, error: reason)
      )
    end
    return false unless previous_status

    reload
    AppLog.info("Order payment rejected", order_id: id, from: previous_status, reason: reason)
    true
  end

  def invoice_expired? = expires_at.present? && Time.current > expires_at

  def formatted_total = format("%d KGS", total_amount.to_i / 100)
  def display_status = OrderStatus.display_name(status)

  # "Капучино (L) x2, Чизкейк x1"
  def format_short_summary = order_items.map(&:short_format).join(", ")

  def format_for_client
    lines = ["☕ Заказ ##{id}", "Статус: #{display_status}", "", "Позиции:"]
    order_items.each { |item| lines << "  • #{item.item_name} x#{item.qty} = #{item.line_total / 100} KGS" }
    lines += ["", "Итого: #{formatted_total}"]
    lines += ["", "Комментарий: #{comment}"] if comment.present?
    lines.join("\n")
  end

  def format_for_barista
    local_time = created_at.in_time_zone(tenant&.time_zone || Time.zone)
    lines = ["━━━━━━━━━━━━━━━━━━━━━━", "☕ Заказ ##{id}", "🕐 #{local_time.strftime('%H:%M')}", "👤 #{client_display_name}", "",
             "Позиции:"]
    order_items.each { |item| lines << "  • #{item.item_name} x#{item.qty}" }
    lines += ["", "💰 #{formatted_total}"]
    lines += ["", "📝 #{comment}"] if comment.present?
    lines << "━━━━━━━━━━━━━━━━━━━━━━"
    lines.join("\n")
  end

  private

  # Conditional UPDATE: changes status only if the row is still in one of
  # from_statuses and has no settled payment yet. Must run inside a transaction.
  #
  # @return [String, nil] previous status for the winner, nil if nothing changed
  def atomic_status_change!(from_statuses, to_status, extra_columns = {})
    allowed = from_statuses.select { |s| OrderStatus.can_transition?(s, to_status) }

    # Second attempt covers a status change between the read and the UPDATE
    2.times do
      current = self.class.lock.where(id: id).pick(:status)
      return nil unless allowed.include?(current)

      changed = self.class.where(id: id, status: current)
                          .where(settled_payment_exists.not)
                          .update_all(extra_columns.merge(status: to_status, updated_at: Time.current))
      return current if changed == 1
    end

    nil
  end

  def settled_payment_exists
    Payment.where(order_id: id, status: PaymentStatus::SETTLED).arel.exists
  end

  # Create or update the payment record (inside the caller's transaction)
  def save_payment_record!(attrs)
    attrs = attrs.merge(invoice_id_provider: invoice_id_provider)
    record = Payment.lock.find_by(order_id: id)
    record ? record.update!(attrs) : Payment.create!(attrs.merge(order_id: id))
  end

  # Provider data for audit, without the signature
  def payment_details_json(raw_response, extra = {})
    raw = raw_response.is_a?(Hash) ? raw_response.reject { |k, _| k.to_s == "hash" } : raw_response
    { provider: raw, **extra }.to_json
  end

  # Provider amount -> Integer tyiyn (nil when missing or unparseable)
  def amount_to_integer(value)
    Payment.parse_amount(value)&.to_i
  rescue ArgumentError
    nil
  end
end
