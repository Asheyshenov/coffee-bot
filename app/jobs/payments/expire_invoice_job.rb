# frozen_string_literal: true

module Payments
  # Closes an unpaid invoice at its payment deadline (order created_at + the tenant's
  # order_expire_minutes):
  #   1. last-chance payment check at MWallet (the customer may have paid without a callback)
  #   2. invoiceCancel at MWallet so the QR can no longer be paid
  #   3. Order#expire! (conditional: a payment that landed meanwhile is never overwritten)
  #   4. tell the customer, then schedule late-payment checks
  # Safe to run more than once for the same order.
  class ExpireInvoiceJob < TenantJob
    queue_as :default

    CLIENT_OPTIONS = { timeout: 15, retry_count: 1 }.freeze

    def self.schedule(order)
      enqueue_for(order, wait_until: order.payment_deadline)
    end

    def perform_in_tenant(order_id)
      order = Order.find_by(id: order_id)
      return unless order&.status == OrderStatus::INVOICE_CREATED

      # Fired early (e.g. the shop gave customers more time since): come back at the deadline
      return self.class.schedule(order) unless order.payment_deadline_passed?

      expire(order)
    end

    private

    # @return [Boolean] true if the order was marked EXPIRED
    def expire(order)
      result = last_chance_sync(order)
      if NotifyResultJob.notify_later(order, result)
        AppLog.info("Payment found before expiry, skipping expiry", order_id: order.id, payment_error: result[:payment_error])
        return false
      end

      order.reload
      unless order.status == OrderStatus::INVOICE_CREATED
        AppLog.info("Skipping expiry: status changed during payment check", order_id: order.id, status: order.status)
        # MWallet already closed the invoice: nobody else tells the customer
        notify_client_expired(order, OrderStatus::CANCELLED) if result[:invoice_cancelled]
        return false
      end

      cancel_invoice_at_provider(order)

      # A callback may have paid the order while we talked to the provider:
      # expire! only changes an INVOICE_CREATED row
      unless order.expire!
        AppLog.info("Skipping expiry: order status changed concurrently", order_id: order.id, status: order.status)
        return false
      end

      LatePaymentCheckJob.schedule(order) if order.invoice_id_provider.present?
      notify_client_expired(order, OrderStatus::EXPIRED)
      true
    end

    # Provider unreachable: expire anyway instead of keeping the order open forever
    def last_chance_sync(order)
      service(order).sync_status(order)
    rescue StandardError => e
      AppLog.error("Last-chance payment check failed, expiring anyway", order_id: order.id, error: "#{e.class}: #{e.message}")
      {}
    end

    # Errors are only logged: the order is expired locally either way
    # (MWallet::Service#cancel_invoice_for_order is not used: it sets CANCELLED)
    def cancel_invoice_at_provider(order)
      return if order.invoice_id_provider.blank?

      service(order).client.cancel_invoice(order.invoice_id_provider)
      AppLog.info("Cancelled expired invoice at MWallet", order_id: order.id, invoice_id: order.invoice_id_provider)
    rescue StandardError => e
      AppLog.error("Failed to cancel expired invoice at MWallet", order_id: order.id, error: "#{e.class}: #{e.message}")
    end

    # @param notified_status [String] recorded as last_notified_status once delivered
    def notify_client_expired(order, notified_status)
      if Notifier.for(ActsAsTenant.current_tenant).notify_invoice_expired(order)
        order.update_column(:last_notified_status, notified_status)
        AppLog.info("Notified client about expired order", order_id: order.id)
      else
        AppLog.error("Failed to notify client about expired order", order_id: order.id)
      end
    rescue StandardError => e
      AppLog.error("Failed to notify client about expired order", order_id: order.id, error: "#{e.class}: #{e.message}")
    end

    def service(order)
      @service ||= MWallet::Service.for_order(order, **CLIENT_OPTIONS)
    end
  end
end
