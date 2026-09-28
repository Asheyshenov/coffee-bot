# frozen_string_literal: true

# MWallet Service
# High-level service for mwallet operations
# Handles business logic, idempotency, and error handling

require_relative 'mwallet_client'
require_relative 'status_mapper'
require_relative 'errors'
require 'bigdecimal'

module MWallet
  class Service
    attr_reader :client

    def initialize(config = {})
      @client = Client.new(config)
    end

    # Create invoice for order
    # Implements idempotency - won't create duplicate invoices
    #
    # @param order [Order] The order to create invoice for
    # @return [Hash] Invoice data with paylink_url, qr_url, etc.
    # @raise [MWalletError::Base] On error
    def create_invoice_for_order(order)
      # Check idempotency - if invoice already exists and is valid, return it
      if order.invoice_id_provider && order.status == OrderStatus::INVOICE_CREATED
        if !order.invoice_expired?
          log_info('Invoice already exists, returning existing', order_id: order.id)
          return existing_invoice_data(order)
        end
      end

      # Create new invoice
      params = {
        order_id: order.merchant_invoice_id,
        desc: "Заказ ##{order.id} - Coffee Bot",
        amount: order.total_amount,
        currency: order.currency || 'KGS',
        result_url: CoffeeBot::Config::MWALLET_CALLBACK_URL,
        date_life: CoffeeBot::Config::ORDER_EXPIRE_MINUTES * 60
      }

      response = client.create_invoice(params)

      # Extract invoice data from response
      invoice_data = extract_invoice_data(response)

      # Update order with invoice data and provider
      order.set_invoice_data(invoice_data)
      order.update(provider: 'MWALLET')
      # Re-issuing an expired invoice keeps the order in INVOICE_CREATED
      order.transition_to!(OrderStatus::INVOICE_CREATED) unless order.status == OrderStatus::INVOICE_CREATED

      log_info('Invoice created successfully', order_id: order.id, invoice_id: invoice_data[:invoice_id])

      invoice_data
    rescue MWalletError::Base => e
      log_error('Failed to create invoice', order_id: order.id, error: e.message)
      order.update(
        status: OrderStatus::ERROR,
        raw_create_response: { error: e.message, code: e.code }.to_json
      )
      raise
    end

    # Get payment status from provider
    #
    # @param order [Order] The order to check
    # @return [Hash] Status data
    def get_payment_status(order)
      response = client.get_status(order.invoice_id_provider)

      # MWallet returns the status either in data.payments[] or directly in data.status
      # (e.g. {"data":{"status":"processing"}} for an unpaid invoice). Depending on the
      # merchant it is text ("approved") or a code (3 / "3"), see StatusMapper.
      # Prefer a successful payment: an earlier rejected attempt must not hide it.
      data = response['data'] || response[:data] || {}
      payments = data['payments'] || data[:payments] || []
      payments = [] unless payments.is_a?(Array)
      payment = payments.find { |p| StatusMapper.map_from_provider(p['status'] || p[:status]) == :paid } ||
                payments.first || {}

      provider_status = payment['status'] || payment[:status]
      provider_status = data['status'] || data[:status] if provider_status.nil?
      internal_status = StatusMapper.map_from_provider(provider_status)

      if internal_status == :unknown
        log_warn('Unknown MWallet payment status, ignoring', invoice_id: order.invoice_id_provider,
          provider_status: provider_status.inspect)
      end

      {
        provider_status: provider_status,
        internal_status: internal_status,
        paid_amount: payment['amount'] || payment[:amount] || data['amount'] || data[:amount],
        payment: payment,
        raw_response: response
      }
    end

    # Sync order status with provider
    # Updates order and payment records based on current provider status.
    # Also detects late payments (order already EXPIRED/CANCELLED -> refund required).
    #
    # @param order [Order] The order to sync
    # @return [Hash] :updated, :order_id, :notify_barista; optional :late_payment,
    #   :refund_required, :previous_status, :payment_error, :expected_amount, :paid_amount
    def sync_status(order)
      return { updated: false, order_id: nil, notify_barista: false } unless order.invoice_id_provider

      status_data = get_payment_status(order)

      log_info('Syncing order status',
        order_id: order.id,
        provider_status: status_data[:provider_status],
        internal_status: status_data[:internal_status]
      )

      case status_data[:internal_status]
      when :paid
        return apply_paid_status(order, status_data[:paid_amount], source: 'polling', raw_response: status_data[:payment])
      when :cancelled
        # Only an unpaid invoice is closed. The provider snapshot may be stale (e.g. a
        # declined first attempt) while a retry was just paid via callback: a PAID order
        # or one with a settled payment is never moved to CANCELLED.
        settled_payment = Payment.where(order_id: order.id, status: PaymentStatus::SETTLED)
        cancelled = Order.where(id: order.id, status: OrderStatus::INVOICE_CREATED)
                         .exclude(settled_payment.exists)
                         .update(status: OrderStatus::CANCELLED, updated_at: Time.now.utc)
        if cancelled == 1
          order.refresh
          return { updated: true, order_id: order.id, notify_barista: false }
        end
      end

      { updated: false, order_id: order.id, notify_barista: false }
    end

    # Cancel invoice for order
    # Calls InvoiceCancel API and updates order status
    #
    # @param order [Order] The order to cancel
    # @return [Boolean] True if cancelled successfully
    def cancel_invoice_for_order(order)
      return false unless order.invoice_id_provider
      return false unless [OrderStatus::INVOICE_CREATED, OrderStatus::NEW].include?(order.status)

      begin
        response = client.cancel_invoice(order.invoice_id_provider)
        log_info('Invoice cancelled via API', order_id: order.id, invoice_id: order.invoice_id_provider)
        
        # Update order status
        cancel_order_locally(order)
        true
      rescue MWalletError::Base => e
        log_error('Failed to cancel invoice', order_id: order.id, error: e.message)
        # Still cancel the order locally even if API fails
        cancel_order_locally(order)
        false
      end
    end

    # Process callback from mwallet
    #
    # @param params [Hash] Callback parameters
    # @param raw_body [String] Raw request body
    # @return [Hash] :success, :order_id, :notify_barista (+ same optional keys as #sync_status)
    # @raise [MWalletError::ValidationError] On empty body
    # @raise [MWalletError::SignatureError] On invalid signature
    def process_callback(params, raw_body)
      raise MWalletError::ValidationError.new('Empty callback body') if raw_body.to_s.strip.empty?

      invoice_id = param(params, 'invoice_id')&.to_s

      # Duplicate check BEFORE logging, otherwise the callback finds its own log row.
      # MWallet sends no per-event id (invoice_id repeats for every status update),
      # so dedupe relies on dedupe_key = sha256(raw body) + invoice id.
      duplicate = CallbackLog.duplicate?(nil, invoice_id, raw_body)

      callback_log = CallbackLog.log_callback(
        provider: 'MWALLET',
        event_id: nil,
        invoice_id: invoice_id,
        merchant_invoice_id: param(params, 'order_id')&.to_s,
        raw_body: raw_body,
        verified: false
      )

      # Verify signature
      unless client.verify_callback_signature(params)
        callback_log.mark_failed!('Invalid signature')
        log_error('Callback signature verification failed', invoice_id: invoice_id)
        raise MWalletError::SignatureError.new('Invalid signature')
      end

      callback_log.mark_verified!

      if duplicate
        log_info('Duplicate callback detected, skipping', invoice_id: invoice_id)
        callback_log.mark_duplicate!
        return { success: true, order_id: nil, notify_barista: false }
      end

      begin
        order = Order.where(invoice_id_provider: invoice_id).first if invoice_id && !invoice_id.empty?

        unless order
          log_error('Order not found for callback', invoice_id: invoice_id)
          callback_log.mark_failed!('Order not found')
          return { success: true, order_id: nil, notify_barista: false } # Return success to acknowledge receipt
        end

        internal_status = StatusMapper.map_from_provider(param(params, 'status'))

        result = if internal_status == :paid
                   apply_paid_status(order, param(params, 'amount'), source: 'callback', raw_response: params)
                 else
                   { updated: false, order_id: order.id, notify_barista: false }
                 end

        callback_log.mark_processed!
        { success: true, **result }
      rescue StandardError => e
        # Not "handled": a provider retry of the same body will be processed again
        callback_log.mark_failed!("#{e.class}: #{e.message}")
        raise
      end
    end

    private

    # Apply a provider "paid" status (callback or polling)
    # Verifies the amount, then performs the atomic transition. Only the caller that
    # actually changed the order gets notify flags, so notifications go out once.
    # Payments for EXPIRED/CANCELLED orders are not fulfilled: they become refunds.
    #
    # @return [Hash] Result, see #sync_status
    def apply_paid_status(order, raw_amount, source:, raw_response:)
      return apply_late_payment(order, raw_amount, source: source, raw_response: raw_response) if late_payment_order?(order)

      verdict, amount = check_paid_amount(order, raw_amount)

      if %i[insufficient invalid].include?(verdict)
        return reject_payment(order, raw_amount, amount, source: source, raw_response: raw_response)
      end

      if verdict == :missing
        log_warn('Provider reported payment without amount, accepting it', order_id: order.id, source: source)
      end

      paid = order.mark_paid!(
        paid_amount: amount&.to_i,
        paid_at: Time.now.utc,
        raw_response: raw_response
      )

      unless paid
        # The expirer / a cancel may have closed the order a moment ago: the money
        # still has to go back to the client
        return apply_late_payment(order, raw_amount, source: source, raw_response: raw_response) if late_payment_order?(order)

        log_info('Payment already applied or order not payable, skipping', order_id: order.id, status: order.status, source: source)
        return { updated: false, order_id: order.id, notify_barista: false }
      end

      log_info("Order marked as paid via #{source}", order_id: order.id)
      { updated: true, order_id: order.id, notify_barista: true }
    end

    # Payment for an order that already EXPIRED / was CANCELLED
    # The order is not fulfilled; the payment is recorded as REFUND_REQUIRED and only
    # the winner gets :refund_required, so staff and client are told exactly once.
    # Any amount (even below the total) is refunded, so no amount check here.
    def apply_late_payment(order, raw_amount, source:, raw_response:)
      amount = begin
        Payment.parse_amount(raw_amount)
      rescue ArgumentError
        nil
      end
      paid_amount = amount&.to_i || order.total_amount

      previous_status = order.record_late_payment!(
        paid_amount: paid_amount,
        paid_at: Time.now.utc,
        raw_response: raw_response
      )

      unless previous_status
        log_info('Late payment already recorded, skipping', order_id: order.id, status: order.status, source: source)
        return { updated: false, order_id: order.id, notify_barista: false }
      end

      log_warn("Late payment via #{source}: order was #{previous_status}, refund required",
        order_id: order.id, paid_amount: paid_amount, invoice_id: order.invoice_id_provider)

      {
        updated: true,
        order_id: order.id,
        notify_barista: false,
        late_payment: true,
        refund_required: true,
        previous_status: previous_status,
        paid_amount: paid_amount
      }
    end

    # Fresh status check: the in-memory order may be stale
    def late_payment_order?(order)
      OrderStatus::LATE_PAYMENT.include?(Order.where(id: order.id).get(:status))
    end

    # Move order to ERROR when the paid amount can't be accepted
    # Only the winner of the transition gets :payment_error, so baristas are alerted once.
    def reject_payment(order, raw_amount, amount, source:, raw_response:)
      reason = amount ? 'AMOUNT_MISMATCH' : 'AMOUNT_UNPARSEABLE'
      rejected = order.mark_payment_error!(
        reason: "#{reason}: expected #{order.total_amount}, got #{raw_amount.inspect}",
        paid_amount: amount&.to_i,
        raw_response: raw_response
      )

      unless rejected
        log_info('Payment problem already handled, skipping', order_id: order.id, status: order.status, source: source)
        return { updated: false, order_id: order.id, notify_barista: false }
      end

      log_error('Paid amount is less than order total, order moved to ERROR',
        order_id: order.id, expected: order.total_amount, got: raw_amount, source: source)

      {
        updated: true,
        order_id: order.id,
        notify_barista: false,
        payment_error: reason.downcase.to_sym,
        expected_amount: order.total_amount,
        paid_amount: amount
      }
    end

    # Compare provider amount with order total (same unit: tyiyn). Overpayment is accepted.
    #
    # @return [Array(Symbol, BigDecimal)] [:ok | :missing | :insufficient | :invalid, amount]
    def check_paid_amount(order, raw_amount)
      amount = Payment.parse_amount(raw_amount)
      return [:missing, nil] if amount.nil?

      [amount >= BigDecimal(order.total_amount.to_s) ? :ok : :insufficient, amount]
    rescue ArgumentError
      [:invalid, nil]
    end

    # Cancel locally without overwriting a status that changed concurrently
    # (e.g. the order was just paid via callback)
    def cancel_order_locally(order)
      Order.where(id: order.id, status: [OrderStatus::INVOICE_CREATED, OrderStatus::NEW])
           .update(status: OrderStatus::CANCELLED, updated_at: Time.now.utc)
      order.refresh
    end

    # Read callback param by string or symbol key
    def param(params, key)
      params[key] || params[key.to_sym]
    end

    def log_warn(message, context = {})
      CoffeeBot::LOG.warn(context.empty? ? message : { message: message, **context })
    end

    # Extract invoice data from API response
    def extract_invoice_data(response)
      data = response['data'] || response[:data] || {}
      
      {
        invoice_id: data['invoice_id'] || data[:invoice_id],
        qr_url: data['qr_url'] || data[:qr_url],
        paylink_url: data['paylink_url'] || data[:paylink_url],
        emv_qr_url: data['emv_qr'] || data[:emv_qr],  # URL to QR image
        qr_image_base64: data['emv_qr_img'] || data[:emv_qr_img],
        emv_qr_data: data['emv_qr_data'] || data[:emv_qr_data],
        raw_response: response.to_json
      }
    end

    # Get existing invoice data from order
    def existing_invoice_data(order)
      {
        invoice_id: order.invoice_id_provider,
        qr_url: order.qr_url,
        paylink_url: order.qr_url, # Using qr_url field for paylink
        emv_qr_url: order.emv_qr_url,
        qr_image_base64: order.qr_image_base64,
        raw_response: order.raw_create_response
      }
    end
  end
end
