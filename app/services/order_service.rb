# frozen_string_literal: true

# Order lifecycle of the current coffee shop, as used by the bot
class OrderService
  class NoPaymentAccount < StandardError; end

  # Statuses a client may cancel by themselves (nothing has been charged yet)
  CLIENT_CANCELLABLE = [ OrderStatus::NEW, OrderStatus::INVOICE_CREATED ].freeze

  NOT_SYNCED = { updated: false, order_id: nil, notify_barista: false }.freeze

  # Create an order from the customer's cart (current menu prices)
  #
  # @return [Order, nil] nil if the cart is empty or has unavailable items
  def self.create_from_draft(draft, customer)
    order = Order.create_from_draft(draft, customer)
    unless order
      AppLog.info("Order not created: cart is empty or has unavailable items", client: customer.telegram_user_id)
      return nil
    end

    AppLog.info("Order created", order_id: order.id, client: customer.display_name, total: order.formatted_total)
    order
  end

  # Issue the MWallet invoice of an order from the coffee shop's payment account
  #
  # @return [Hash] invoice data (paylink_url, emv_qr_url, ...)
  # @raise [NoPaymentAccount, MWalletError::Base]
  def self.create_invoice(order)
    account = payment_account_for(order)
    raise NoPaymentAccount, "No active payment account for tenant #{order.tenant_id}" unless account

    order.update!(payment_account: account) if order.payment_account_id.nil?
    MWallet::Service.new(account).create_invoice_for_order(order)
  rescue StandardError => e
    AppLog.error("Failed to create invoice", order_id: order.id, error: "#{e.class}: #{e.message}")
    raise
  end

  # @return [Array<Order>] newest first
  def self.client_orders(telegram_user_id, limit: 10)
    Order.for_user(telegram_user_id).limit(limit).to_a
  end

  # @return [Order, nil] oldest active order (awaiting payment, paid or in preparation)
  def self.active_order_for_client(telegram_user_id) = active_scope(telegram_user_id).first

  # @return [Array<Order>]
  def self.active_orders_for_client(telegram_user_id) = active_scope(telegram_user_id).includes(:order_items).to_a

  # Paid orders waiting for a barista
  def self.barista_queue = Order.ready_for_barista.includes(:order_items).to_a

  # Orders a barista is preparing
  def self.barista_in_progress(barista_id) = Order.for_barista(barista_id).order(:created_at).includes(:order_items).to_a

  # Claim a paid order (atomic: only one barista wins)
  def self.claim_order(order_id, barista_id)
    order = Order.find_by(id: order_id)
    return false unless order

    order.claim_for_barista!(barista_id)
  end

  # Mark an order ready; only the barista who claimed it may do so
  def self.complete_order(order_id, barista_id)
    order = Order.find_by(id: order_id)
    return false unless order && order.assigned_to_barista_id == barista_id

    order.mark_ready!
  end

  # Cancel an order on the client's request (/cancel)
  #
  # Only unpaid orders (NEW / INVOICE_CREATED) are cancelled. Before cancelling an
  # invoice a last-chance payment sync is done, so a payment that has just arrived is
  # not thrown away. PAID / IN_PROGRESS orders are never cancelled here: that requires
  # a refund and goes through the barista.
  #
  # If that sync is the one that changed the order (payment found, or a payment that
  # must not be accepted), nobody else will announce it: the sync result is yielded so
  # the caller sends the notifications (Notifier#notify_payment_result).
  #
  # @yieldparam sync_result [Hash] winning result of #sync_payment_status
  # @return [Symbol] :cancelled, :cancelled_locally (provider did not confirm the invoice
  #   cancel), :paid_now (result yielded), :payment_problem (result yielded),
  #   :already_paid, :in_progress, :not_cancellable
  def self.cancel_by_client(order)
    outcome = client_cancel_blocker(order)

    if outcome.nil? && order.status == OrderStatus::INVOICE_CREATED
      result = last_chance_sync(order)
      settled = result[:notify_barista] || result[:payment_error] || result[:refund_required]
      yield result if settled && block_given?
      outcome = client_cancel_blocker(order.reload, settled_now: settled)
    end

    outcome ||= cancel_unpaid_order(order)
    AppLog.info("Client cancel request processed", order_id: order.id, outcome: outcome, status: order.status)
    outcome
  end

  # Sync the order with MWallet; the result is returned unchanged
  #
  # @return [Hash] :updated, :order_id, :notify_barista (+ :late_payment, :refund_required,
  #   :previous_status, :paid_amount, :payment_error, :expected_amount)
  def self.sync_payment_status(order)
    return NOT_SYNCED.dup unless order.invoice_id_provider

    account = payment_account_for(order)
    raise NoPaymentAccount, "No payment account for order #{order.id}" unless account

    MWallet::Service.new(account).sync_status(order)
  end

  # The account the invoice was issued from, else the shop's active one
  def self.payment_account_for(order)
    order.payment_account || order.tenant&.payment_account
  end

  def self.active_scope(telegram_user_id)
    Order.where(telegram_user_id: telegram_user_id, status: OrderStatus::ACTIVE).order(:created_at, :id)
  end

  # Why the client cannot (or no longer needs to) cancel the order
  #
  # @return [Symbol, nil] nil if the order can be cancelled
  def self.client_cancel_blocker(order, settled_now: false)
    case order.status
    when *CLIENT_CANCELLABLE then nil
    when OrderStatus::PAID then settled_now ? :paid_now : :already_paid
    when OrderStatus::IN_PROGRESS then :in_progress
    when OrderStatus::CANCELLED then :cancelled
    when OrderStatus::ERROR then settled_now ? :payment_problem : :not_cancellable
    else :not_cancellable
    end
  end

  # Sync right before cancelling; errors must not block the cancel
  def self.last_chance_sync(order)
    sync_payment_status(order)
  rescue StandardError => e
    AppLog.error("Last-chance payment sync failed, cancelling anyway", order_id: order.id, error: "#{e.class}: #{e.message}")
    {}
  end

  # Cancel an unpaid order: invoice at the provider first, then locally.
  # A CANCELLED order with a still payable invoice (:cancelled_locally) is not lost:
  # late-payment polling keeps checking it.
  def self.cancel_unpaid_order(order)
    api_cancelled = order.invoice_id_provider.present? && cancel_invoice_at_provider(order)

    # Conditional update: a no-op if the order was cancelled or paid meanwhile
    order.cancel_unpaid!

    # Judge by the stored status, not by the API flag: the order may have been paid
    # (callback / polling) while the cancel request was in flight
    if order.reload.status == OrderStatus::CANCELLED
      api_cancelled || order.invoice_id_provider.nil? ? :cancelled : :cancelled_locally
    else
      client_cancel_blocker(order) || :not_cancellable
    end
  end

  def self.cancel_invoice_at_provider(order)
    account = payment_account_for(order)
    return false unless account

    MWallet::Service.new(account).cancel_invoice_for_order(order) == true
  rescue StandardError => e
    AppLog.error("Failed to cancel invoice via API", order_id: order.id, error: "#{e.class}: #{e.message}")
    false
  end

  private_class_method :active_scope, :client_cancel_blocker, :last_chance_sync, :cancel_unpaid_order,
                       :cancel_invoice_at_provider
end
