# frozen_string_literal: true

require "bigdecimal"

module MWallet
  # Payment business logic on top of MWallet::Client for one merchant account
  # (one coffee shop). Must run inside the account's tenant.
  #
  # Every status change goes through the atomic Order methods, so of several racing
  # callers (callback, polling, expiry, a customer cancelling) exactly one wins. Only
  # the winner's result carries notification flags; pass it to
  # Payments::NotifyResultJob.notify_later, so each message is sent once.
  #
  # Only the provider API changes an order: a callback is a signed trigger, not a proof
  # of payment. Its status / amount are logged as a hint and the payment is confirmed
  # with statusPayment (credentials of the order's payment account) before anything is
  # applied, so even a correctly signed forged callback can't mark an order paid.
  #
  # Result hash of #sync_status / #process_callback:
  #   :updated, :order_id, :notify_barista - always
  #   :late_payment, :refund_required, :previous_status, :paid_amount - paid after EXPIRED / CANCELLED
  #   :payment_error, :expected_amount, :paid_amount - payment not accepted (order moved to ERROR)
  #   :invoice_cancelled - the provider closed the unpaid invoice (order moved to CANCELLED)
  #   :success, :confirmed - #process_callback only (:confirmed false: statusPayment did
  #     not confirm the callback or could not be reached; polling picks it up)
  class Service
    PROVIDER = "MWALLET"

    attr_reader :payment_account, :client

    # Service for the account the order's invoice was issued from
    # (the tenant's active account for an order without one yet)
    #
    # @param client_options [Hash] MWallet::Client overrides (timeout:, retry_count:)
    def self.for_order(order, **client_options)
      account = order.payment_account || ActsAsTenant.current_tenant&.payment_account
      raise ArgumentError, "No payment account for order #{order.id}" unless account

      new(account, **client_options)
    end

    # @param payment_account [PaymentAccount]
    # @param client [MWallet::Client, nil] defaults to payment_account.mwallet_client(**client_options)
    def initialize(payment_account, client: nil, **client_options)
      raise ArgumentError, "payment_account is required" unless payment_account

      @payment_account = payment_account
      @client_options = client_options
      @client = client || payment_account.mwallet_client(**client_options)
    end

    # Create the invoice at MWallet and move the order to INVOICE_CREATED.
    # Idempotent: an order that already has a live invoice gets its existing data back.
    # On success the status polling and the expiry jobs are scheduled.
    #
    # @return [Hash] :invoice_id, :qr_url, :paylink_url, :emv_qr_url, :qr_image_base64,
    #   :emv_qr_data, :app_url (O!Dengi app deep link), :expires_at, :raw_response
    # @raise [MWalletError::Base] provider error (a NEW order is moved to ERROR)
    # @raise [Order::InvalidStatusTransition] the order can't get an invoice (paid, cancelled, overdue...)
    def create_invoice_for_order(order)
      ensure_same_tenant!(order)

      if order.status == OrderStatus::INVOICE_CREATED && order.invoice_id_provider.present?
        raise Order::InvalidStatusTransition, "Payment time of order #{order.id} is over" if order.payment_deadline_passed?

        AppLog.info("Invoice already exists, returning existing", order_id: order.id)
        return existing_invoice_data(order)
      end
      unless [ OrderStatus::NEW, OrderStatus::INVOICE_CREATED ].include?(order.status)
        raise Order::InvalidStatusTransition, "Cannot create an invoice for a #{order.status} order"
      end

      invoice_data = request_invoice(order)
      store_invoice!(order, invoice_data)

      AppLog.info("Invoice created", order_id: order.id, invoice_id: invoice_data[:invoice_id])
      Payments::PollStatusJob.schedule(order)
      Payments::ExpireInvoiceJob.schedule(order)
      invoice_data
    end

    # Current payment status at the provider
    #
    # @return [Hash] :provider_status, :internal_status, :paid_amount, :payment, :raw_response
    def get_payment_status(order)
      response = client_for(order).get_status(order.invoice_id_provider)

      # The status is in data.payments[] or directly in data.status
      # ({"data":{"status":"processing"}} for an unpaid invoice); text ("approved") or a
      # code (3 / "3") depending on the merchant. A successful payment wins over an
      # earlier rejected attempt.
      data = response["data"] || response[:data]
      data = {} unless data.is_a?(Hash)
      payments = data["payments"] || data[:payments]
      payments = [] unless payments.is_a?(Array)
      payments = payments.select { |p| p.is_a?(Hash) }
      payment = payments.find { |p| StatusMapper.map_from_provider(p["status"] || p[:status]) == :paid } ||
                payments.first || {}

      provider_status = payment["status"] || payment[:status]
      provider_status = data["status"] || data[:status] if provider_status.nil?
      internal_status = StatusMapper.map_from_provider(provider_status)

      if internal_status == :unknown
        AppLog.warn("Unknown MWallet payment status, ignoring", order_id: order.id, invoice_id: order.invoice_id_provider,
                                                                  provider_status: provider_status.inspect)
      end

      {
        provider_status: provider_status,
        internal_status: internal_status,
        paid_amount: payment["amount"] || payment[:amount] || data["amount"] || data[:amount],
        payment: payment.presence || data,
        raw_response: response
      }
    end

    # Poll the provider and apply its status (fallback for callbacks). Also detects
    # late payments: money for an order that already EXPIRED / was CANCELLED.
    #
    # @return [Hash] see the class comment
    def sync_status(order)
      return { updated: false, order_id: nil, notify_barista: false } if order.invoice_id_provider.blank?

      ensure_same_tenant!(order)
      apply_provider_status(order, get_payment_status(order), source: "polling")
    end

    # Cancel the invoice at MWallet, then cancel the order locally (conditionally: a
    # payment that landed meanwhile is never overwritten). The order is cancelled
    # locally even if the provider call fails; late-payment checks are scheduled for it.
    #
    # @return [Boolean] true only if the provider confirmed the cancellation
    def cancel_invoice_for_order(order)
      return false if order.invoice_id_provider.blank?
      return false unless [ OrderStatus::INVOICE_CREATED, OrderStatus::NEW ].include?(order.status)

      ensure_same_tenant!(order)
      confirmed = cancel_at_provider(order)

      if order.cancel_unpaid!
        AppLog.info("Order cancelled", order_id: order.id, provider_confirmed: confirmed)
        # The invoice may still be payable (cancel not confirmed) or a payment in flight
        Payments::LatePaymentCheckJob.schedule(order)
      end
      confirmed
    end

    # Handle a payment result callback sent to this account's result_url.
    # The callback only triggers a statusPayment check of its order (see the class comment).
    #
    # @param params [Hash] parsed callback body (string keys, in the order received)
    # @param raw_body [String]
    # @return [Hash] :success, :confirmed plus the keys of #sync_status
    # @raise [MWalletError::ValidationError] empty body
    # @raise [MWalletError::SignatureError] signature not made with this account's password
    def process_callback(params, raw_body)
      raise MWalletError::ValidationError, "Empty callback body" if raw_body.to_s.strip.empty?

      invoice_id = param(params, "invoice_id")&.to_s.presence

      # Duplicate check BEFORE logging, otherwise the callback finds its own log row.
      # MWallet sends no per-event id (invoice_id repeats for every status update), so
      # dedupe relies on sha256(raw body) + invoice id.
      duplicate = CallbackLog.duplicate?(nil, invoice_id, raw_body)

      callback_log = CallbackLog.log_callback(payment_account: payment_account, raw_body: raw_body,
                                              invoice_id: invoice_id,
                                              merchant_invoice_id: param(params, "order_id")&.to_s.presence)

      unless client.verify_callback_signature(params)
        callback_log.mark_failed!("Invalid signature")
        AppLog.error("Callback signature verification failed", payment_account_id: payment_account.id, invoice_id: invoice_id)
        raise MWalletError::SignatureError, "Invalid signature"
      end
      callback_log.mark_verified!

      if duplicate
        AppLog.info("Duplicate callback, skipping", invoice_id: invoice_id)
        callback_log.mark_duplicate!
        return { success: true, confirmed: false, updated: false, order_id: nil, notify_barista: false }
      end

      handle_verified_callback(params, invoice_id, callback_log)
    end

    private

    def handle_verified_callback(params, invoice_id, callback_log)
      order = invoice_id && Order.find_by(payment_account_id: payment_account.id, invoice_id_provider: invoice_id)
      unless order
        AppLog.error("Order not found for callback", payment_account_id: payment_account.id, invoice_id: invoice_id)
        callback_log.mark_failed!("Order not found")
        # Acknowledged: a retry would not find it either
        return { success: true, confirmed: false, updated: false, order_id: nil, notify_barista: false }
      end

      hint = StatusMapper.map_from_provider(param(params, "status"))
      AppLog.info("MWallet callback, confirming with statusPayment", order_id: order.id, invoice_id: invoice_id,
                  callback_status: param(params, "status").inspect, callback_amount: param(params, "amount").inspect)

      status_data = confirm_with_provider(order, callback_log)
      return { success: true, confirmed: false, updated: false, order_id: order.id, notify_barista: false } unless status_data

      result = apply_provider_status(order, status_data, source: "callback")
      if hint == :paid && status_data[:internal_status] != :paid
        # Forged or early: not "handled", so a provider retry of the same body is checked again
        AppLog.warn("Paid callback not confirmed by MWallet", order_id: order.id,
                                                              provider_status: status_data[:provider_status].inspect)
        callback_log.mark_failed!("Not confirmed by statusPayment: #{status_data[:provider_status].inspect}")
        return { success: true, confirmed: false, **result }
      end

      callback_log.mark_processed!
      { success: true, confirmed: true, **result }
    rescue StandardError => e
      # Not "handled": a provider retry of the same body is processed again
      callback_log.mark_failed!("#{e.class}: #{e.message}")
      raise
    end

    # statusPayment for a callback; nil (logged, nothing changed) when MWallet can't be asked
    def confirm_with_provider(order, callback_log)
      get_payment_status(order)
    rescue MWalletError::Base => e
      AppLog.warn("Could not confirm callback with statusPayment, leaving it to polling", order_id: order.id,
                                                                                          error: "#{e.class}: #{e.message}")
      callback_log.mark_failed!("Confirmation failed: #{e.class.name.demodulize}")
      nil
    end

    # Apply a statusPayment answer
    def apply_provider_status(order, status_data, source:)
      AppLog.info("Applying MWallet status", order_id: order.id, source: source,
                                             provider_status: status_data[:provider_status].inspect,
                                             internal_status: status_data[:internal_status])

      case status_data[:internal_status]
      when :paid
        apply_paid_status(order, status_data[:paid_amount], source: source, raw_response: status_data[:payment])
      when :cancelled
        close_cancelled_invoice(order)
      else
        { updated: false, order_id: order.id, notify_barista: false }
      end
    end

    def request_invoice(order)
      tenant = order.tenant
      response = client.create_invoice(
        order_id: order.merchant_invoice_id,
        desc: "Заказ ##{order.id} - #{tenant.name}",
        amount: order.total_amount,
        currency: order.currency.presence || "KGS",
        result_url: payment_account.callback_url,
        date_life: tenant.order_expire_minutes * 60
      )
      invoice_data = extract_invoice_data(response)
      raise MWalletError::BusinessError.new("MWallet returned no invoice_id", details: response) if invoice_data[:invoice_id].blank?

      invoice_data.merge(expires_at: order.payment_deadline)
    rescue StandardError => e
      AppLog.error("Failed to create invoice", order_id: order.id, error: e.class.name, code: e.try(:code))
      # Only a NEW order goes to ERROR; an order that changed meanwhile keeps its status
      Order.where(id: order.id, status: OrderStatus::NEW)
           .update_all(status: OrderStatus::ERROR, raw_create_response: { error: e.message, code: e.try(:code) }.to_json,
                       updated_at: Time.current)
      order.reload
      raise
    end

    # Save the invoice and move NEW -> INVOICE_CREATED, unless the order changed
    # (e.g. was cancelled) while the invoice was being created
    def store_invoice!(order, invoice_data)
      moved = Order.transaction do
        order.assign_attributes(provider: PROVIDER, payment_account: payment_account,
                                payment_app_url: invoice_data[:app_url])
        order.set_invoice_data(invoice_data) # saves the attributes above too
        Order.where(id: order.id, status: [ OrderStatus::NEW, OrderStatus::INVOICE_CREATED ])
             .update_all(status: OrderStatus::INVOICE_CREATED, updated_at: Time.current) == 1
      end
      order.reload
      return if moved

      AppLog.warn("Order changed while the invoice was created, cancelling the invoice", order_id: order.id,
                                                                                         status: order.status)
      cancel_at_provider(order)
      Payments::LatePaymentCheckJob.schedule(order) if OrderStatus::LATE_PAYMENT.include?(order.status)
      raise Order::InvalidStatusTransition, "Order #{order.id} is #{order.status}, invoice not issued"
    end

    # @return [Boolean] true if the provider confirmed
    def cancel_at_provider(order)
      response = client_for(order).cancel_invoice(order.invoice_id_provider)
      confirmed = cancel_confirmed?(response)
      AppLog.info("Invoice cancel sent to MWallet", order_id: order.id, invoice_id: order.invoice_id_provider,
                                                    confirmed: confirmed)
      confirmed
    rescue StandardError => e
      AppLog.error("Failed to cancel invoice at MWallet", order_id: order.id, error: "#{e.class}: #{e.message}")
      false
    end

    # {"data":{"success":true}} (sandbox), or a cancelled status
    def cancel_confirmed?(response)
      data = response.is_a?(Hash) ? response["data"] : nil
      return false unless data.is_a?(Hash)

      [ true, "true", 1, "1" ].include?(data["success"]) || StatusMapper.map_from_provider(data["status"]) == :cancelled
    end

    # Provider closed the invoice. Only an unpaid order is cancelled: the snapshot may
    # be stale (a declined first attempt) while a retry was just paid via callback.
    def close_cancelled_invoice(order)
      cancelled = Order.where(id: order.id, status: OrderStatus::INVOICE_CREATED)
                       .where.not(id: Payment.settled.select(:order_id))
                       .update_all(status: OrderStatus::CANCELLED, updated_at: Time.current)
      return { updated: false, order_id: order.id, notify_barista: false } unless cancelled == 1

      order.reload
      AppLog.info("Invoice cancelled by MWallet, order cancelled", order_id: order.id)
      Payments::LatePaymentCheckJob.schedule(order)
      { updated: true, order_id: order.id, notify_barista: false, invoice_cancelled: true }
    end

    # A provider "paid" status (callback or polling). Verifies the amount, then makes
    # the atomic transition; only the caller that changed the order gets notify flags.
    # Payments for EXPIRED / CANCELLED orders are not fulfilled: they become refunds.
    def apply_paid_status(order, raw_amount, source:, raw_response:)
      return apply_late_payment(order, raw_amount, source: source, raw_response: raw_response) if late_payment_order?(order)

      verdict, amount = check_paid_amount(order, raw_amount)
      if %i[insufficient invalid].include?(verdict)
        return reject_payment(order, raw_amount, amount, source: source, raw_response: raw_response)
      end

      AppLog.warn("Provider reported payment without amount, accepting it", order_id: order.id, source: source) if verdict == :missing

      unless order.mark_paid!(paid_amount: amount&.to_i, paid_at: Time.current, raw_response: raw_response)
        # Expiry / a cancel may have closed the order a moment ago: the money still has to go back
        return apply_late_payment(order, raw_amount, source: source, raw_response: raw_response) if late_payment_order?(order)

        AppLog.info("Payment already applied or order not payable, skipping", order_id: order.id, status: order.status,
                                                                                source: source)
        return { updated: false, order_id: order.id, notify_barista: false }
      end

      AppLog.info("Order marked as paid via #{source}", order_id: order.id)
      { updated: true, order_id: order.id, notify_barista: true }
    end

    # Payment for an order that already EXPIRED / was CANCELLED: recorded as
    # REFUND_REQUIRED, only the winner gets :refund_required. Any amount (even below
    # the total) is refunded, so there is no amount check.
    def apply_late_payment(order, raw_amount, source:, raw_response:)
      paid_amount = parse_amount_or_nil(raw_amount)&.to_i || order.total_amount
      previous_status = order.record_late_payment!(paid_amount: paid_amount, paid_at: Time.current, raw_response: raw_response)

      unless previous_status
        AppLog.info("Late payment already recorded, skipping", order_id: order.id, status: order.status, source: source)
        return { updated: false, order_id: order.id, notify_barista: false }
      end

      AppLog.warn("Late payment via #{source}, refund required", order_id: order.id, previous_status: previous_status,
                                                                  paid_amount: paid_amount, invoice_id: order.invoice_id_provider)
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

    # Fresh status: the in-memory order may be stale
    def late_payment_order?(order)
      OrderStatus::LATE_PAYMENT.include?(Order.where(id: order.id).pick(:status))
    end

    # INVOICE_CREATED -> ERROR when the paid amount can't be accepted; only the winner
    # gets :payment_error, so staff are alerted once
    def reject_payment(order, raw_amount, amount, source:, raw_response:)
      reason = amount ? "AMOUNT_MISMATCH" : "AMOUNT_UNPARSEABLE"
      rejected = order.mark_payment_error!(reason: "#{reason}: expected #{order.total_amount}, got #{raw_amount.inspect}",
                                           paid_amount: amount&.to_i, raw_response: raw_response)
      unless rejected
        AppLog.info("Payment problem already handled, skipping", order_id: order.id, status: order.status, source: source)
        return { updated: false, order_id: order.id, notify_barista: false }
      end

      AppLog.error("Paid amount is less than order total, order moved to ERROR", order_id: order.id,
                   expected: order.total_amount, got: raw_amount, source: source)
      {
        updated: true,
        order_id: order.id,
        notify_barista: false,
        payment_error: reason.downcase.to_sym,
        expected_amount: order.total_amount,
        paid_amount: amount
      }
    end

    # Provider amount vs order total (same unit: tyiyn). Overpayment is accepted.
    #
    # @return [Array(Symbol, BigDecimal)] [:ok | :missing | :insufficient | :invalid, amount]
    def check_paid_amount(order, raw_amount)
      amount = Payment.parse_amount(raw_amount)
      return [ :missing, nil ] if amount.nil?

      [ amount >= BigDecimal(order.total_amount.to_s) ? :ok : :insufficient, amount ]
    rescue ArgumentError
      [ :invalid, nil ]
    end

    def parse_amount_or_nil(raw_amount)
      Payment.parse_amount(raw_amount)
    rescue ArgumentError
      nil
    end

    # The order's invoice may have been issued from another (older) account of the shop
    def client_for(order)
      return client if order.payment_account_id.nil? || order.payment_account_id == payment_account.id

      order.payment_account.mwallet_client(**@client_options)
    end

    def ensure_same_tenant!(order)
      return if order.tenant_id == payment_account.tenant_id

      raise ArgumentError, "Order #{order.id} does not belong to the tenant of payment account #{payment_account.id}"
    end

    def param(params, key)
      params[key] || params[key.to_sym]
    end

    def extract_invoice_data(response)
      data = response["data"] || response[:data]
      data = {} unless data.is_a?(Hash)
      data = data.with_indifferent_access

      {
        invoice_id: data[:invoice_id]&.to_s,
        qr_url: data[:qr_url],
        paylink_url: data[:paylink_url],
        emv_qr_url: data[:emv_qr], # URL of the QR image
        qr_image_base64: data[:emv_qr_img],
        emv_qr_data: data[:emv_qr_data],
        app_url: data[:link_app], # opens the invoice in the O!Dengi app
        raw_response: response.to_json
      }
    end

    def existing_invoice_data(order)
      {
        invoice_id: order.invoice_id_provider,
        qr_url: order.qr_url,
        paylink_url: order.qr_url, # qr_url stores the paylink
        emv_qr_url: order.emv_qr_url,
        qr_image_base64: order.qr_image_base64,
        emv_qr_data: order.qr_payload,
        app_url: order.payment_app_url,
        expires_at: order.expires_at,
        raw_response: order.raw_create_response
      }
    end
  end
end
