# frozen_string_literal: true

module Payments
  # Looks for a late payment: money that arrived after the order EXPIRED / was
  # CANCELLED (e.g. invoiceCancel failed and the QR stayed payable). Checks run at
  # CHECK_OFFSETS after the order was closed and stop once a settled payment exists.
  # A winning result (refund required) notifies staff and the customer once.
  class LatePaymentCheckJob < TenantJob
    queue_as :default

    # Check times, counted from the moment the order was closed
    CHECK_OFFSETS = [ 1.minute, 5.minutes, 15.minutes, 1.hour, 6.hours, 24.hours ].freeze
    CLIENT_OPTIONS = { timeout: 15, retry_count: 0 }.freeze

    # Schedule check number `step` (no-op after the last one)
    #
    # @return [Boolean] true if scheduled
    def self.schedule(order, step: 0)
      return false if step >= CHECK_OFFSETS.size

      wait = step.zero? ? CHECK_OFFSETS.first : CHECK_OFFSETS[step] - CHECK_OFFSETS[step - 1]
      enqueue_for(order, step, wait: wait)
      true
    end

    def self.candidate?(order)
      order.present? && OrderStatus::LATE_PAYMENT.include?(order.status) && order.invoice_id_provider.present? &&
        !Payment.settled.exists?(order_id: order.id)
    end

    def perform_in_tenant(order_id, step = 0)
      order = Order.find_by(id: order_id)
      return unless self.class.candidate?(order)

      result = check(order)
      if NotifyResultJob.notify_later(order, result)
        AppLog.warn("Late payment found, refund required", order_id: order.id, step: step)
        return
      end

      order.reload
      self.class.schedule(order, step: step + 1) if self.class.candidate?(order)
    end

    private

    # Errors don't stop the schedule: the next check comes later
    def check(order)
      MWallet::Service.for_order(order, **CLIENT_OPTIONS).sync_status(order)
    rescue StandardError => e
      AppLog.error("Late payment check failed", order_id: order.id, error: "#{e.class}: #{e.message}")
      {}
    end
  end
end
