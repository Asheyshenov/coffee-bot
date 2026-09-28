# frozen_string_literal: true

module Payments
  # Safety net, every minute (config/recurring.yml): in every serving coffee shop,
  # expires INVOICE_CREATED orders well past their payment deadline, i.e. whose
  # Payments::ExpireInvoiceJob was lost. Normally finds nothing.
  class SweepJob < ApplicationJob
    queue_as :default

    # A slow run (provider down) must not overlap with the next one
    limits_concurrency key: "payments-sweep", to: 1, duration: 15.minutes, on_conflict: :discard

    # ExpireInvoiceJob runs at the deadline; give it this long before stepping in
    GRACE_PERIOD = 2.minutes
    # Per shop and run (each order costs up to two provider calls); the rest waits a minute
    BATCH_SIZE = 10

    # @return [Integer] number of orders expired
    def perform
      Tenant.serving.order(:id).to_a.sum do |tenant|
        ActsAsTenant.with_tenant(tenant) { sweep(tenant) }
      rescue StandardError => e
        # One broken shop must not block the others
        AppLog.error("Payments sweep failed", tenant_id: tenant.id, error: "#{e.class}: #{e.message}")
        0
      end
    end

    private

    def sweep(tenant)
      cutoff = Time.current - tenant.order_expire_minutes.minutes - GRACE_PERIOD
      overdue_ids = Order.where(status: OrderStatus::INVOICE_CREATED, created_at: ...cutoff)
                         .order(:created_at, :id).limit(BATCH_SIZE).pluck(:id)

      overdue_ids.count do |order_id|
        AppLog.warn("Overdue unpaid order found by sweep, expiring", order_id: order_id)
        ExpireInvoiceJob.perform_now(tenant.id, order_id)
        Order.where(id: order_id, status: OrderStatus::EXPIRED).exists?
      rescue StandardError => e
        AppLog.error("Failed to expire overdue order", order_id: order_id, error: "#{e.class}: #{e.message}")
        false
      end
    end
  end
end
