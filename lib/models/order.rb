# frozen_string_literal: true

# Order Model
# Main model for tracking orders throughout their lifecycle
# Includes state machine for status transitions

require_relative '../../config/boot'
require_relative 'order_status'
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
  def self.create_from_draft(draft, client)
    order = nil

    DB.transaction do
      # Create the order with pre-generated merchant_invoice_id
      order = create(
        telegram_user_id: client.telegram_user_id,
        client_display_name: client.display_name,
        comment: draft.comment,
        status: OrderStatus::NEW,
        total_amount: draft.total_amount,
        currency: 'KGS',
        merchant_invoice_id: generate_merchant_invoice_id
      )

      # Create order items from draft
      draft.items.each do |item|
        OrderItem.create(
          order_id: order.id,
          menu_item_id: item['menu_item_id'],
          item_name: item['name'],
          qty: item['qty'],
          unit_price: item['unit_price'],
          line_total: item['line_total']
        )
      end

      # Increment client's order count
      client.increment_orders!
    end

    order
  end

  # Instance methods

  # Check if status transition is allowed
  def can_transition_to?(new_status)
    OrderStatus.can_transition?(status, new_status)
  end

  # Transition to new status with validation
  def transition_to!(new_status)
    unless can_transition_to?(new_status)
      raise InvalidStatusTransition, "Cannot transition from #{status} to #{new_status}"
    end

    update(status: new_status)
    log_info('Order status changed', order_id: id, from: status, to: new_status)
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
  def expire!
    return false unless status == OrderStatus::INVOICE_CREATED

    update(status: OrderStatus::EXPIRED)
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

  # Mark as paid
  def mark_paid!(payment_data = {})
    return false unless status == OrderStatus::INVOICE_CREATED

    DB.transaction do
      transition_to!(OrderStatus::PAID)

      # Create or update payment record
      if payment
        payment.update(
          paid_amount: payment_data[:paid_amount] || total_amount,
          paid_at: payment_data[:paid_at] || Time.now.utc,
          status: PaymentStatus::PAID
        )
      else
        Payment.create(
          order_id: id,
          invoice_id_provider: invoice_id_provider,
          paid_amount: payment_data[:paid_amount] || total_amount,
          paid_at: payment_data[:paid_at] || Time.now.utc,
          status: PaymentStatus::PAID
        )
      end
    end

    log_info('Order paid', order_id: id)
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
      price_kgs = item.unit_price.to_f / 100
      total_kgs = item.line_total.to_f / 100
      lines << "  • #{item.item_name} x#{item.qty} = #{'%.2f' % total_kgs} KGS"
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
    kgs = total_amount.to_f / 100
    format('%.2f KGS', kgs)
  end

  # Display status
  def display_status
    OrderStatus.display_name(status)
  end
end

# Custom exception for invalid status transitions
class InvalidStatusTransition < StandardError; end
