# frozen_string_literal: true

module Payments
  # Fallback for lost callbacks: polls MWallet for one unpaid invoice and
  # reschedules itself while the order is INVOICE_CREATED and before its payment
  # deadline (then Payments::ExpireInvoiceJob takes over).
  # Every run is idempotent: notifications go out only for a winning result.
  class PollStatusJob < TenantJob
    queue_as :default

    FAST_INTERVAL = 5.seconds
    SLOW_INTERVAL = 15.seconds
    # The first two minutes (when most customers pay) are polled more often
    FAST_POLLS = 24
    # A poll must not hold a worker for long: the next one comes in seconds anyway
    CLIENT_OPTIONS = { timeout: 10, retry_count: 0 }.freeze

    # Schedule the next poll of the order's current invoice (no-op past the deadline)
    #
    # @return [Boolean] true if scheduled
    def self.schedule(order, attempt: 0)
      wait = attempt < FAST_POLLS ? FAST_INTERVAL : SLOW_INTERVAL
      return false if Time.current + wait >= order.payment_deadline

      enqueue_for(order, order.invoice_id_provider, attempt, wait: wait)
      true
    end

    # @param invoice_id [String] invoice the chain was started for; a re-issued
    #   invoice starts its own chain, so this one stops
    def perform_in_tenant(order_id, invoice_id = nil, attempt = 0)
      order = Order.find_by(id: order_id)
      return unless pollable?(order, invoice_id)

      poll(order)
      order.reload
      self.class.schedule(order, attempt: attempt + 1) if pollable?(order, invoice_id)
    end

    private

    def pollable?(order, invoice_id)
      order.present? && order.status == OrderStatus::INVOICE_CREATED && order.invoice_id_provider.present? &&
        (invoice_id.nil? || order.invoice_id_provider == invoice_id) && !order.payment_deadline_passed?
    end

    def poll(order)
      result = MWallet::Service.for_order(order, **CLIENT_OPTIONS).sync_status(order)
      if NotifyResultJob.notify_later(order, result) || NotifyResultJob.notify_invoice_cancelled_later(order, result)
        AppLog.info("Payment status changed via polling", order_id: order.id)
      end
    rescue StandardError => e
      # Provider down or a bad response: the next poll / the expiry job tries again
      AppLog.error("Payment status poll failed", order_id: order.id, error: "#{e.class}: #{e.message}")
    end
  end
end
