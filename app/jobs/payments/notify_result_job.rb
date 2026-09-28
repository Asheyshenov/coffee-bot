# frozen_string_literal: true

module Payments
  # Sends the Telegram notifications for a payment result
  # (Notifier#notify_payment_result). Enqueue it only with the result of the caller
  # that won the status transition - #notify_later checks the flags.
  # Also tells the customer that MWallet closed their unpaid invoice
  # (#notify_invoice_cancelled_later, for a winning :invoice_cancelled result).
  class NotifyResultJob < TenantJob
    queue_as :default

    RESULT_KEYS = %i[order_id notify_barista late_payment refund_required previous_status paid_amount payment_error
                     expected_amount invoice_cancelled].freeze

    # A result that must be announced (payment accepted, rejected or to be refunded)
    def self.notifiable?(result)
      result = result.to_h
      result[:order_id].present? && (result[:notify_barista] || result[:payment_error] || result[:refund_required]).present?
    end

    # Enqueue the notifications for a winning result
    #
    # @param order [Order]
    # @param result [Hash] result of MWallet::Service#sync_status / #process_callback
    # @param notify_client [Boolean] false when the caller answers the client itself
    # @return [Boolean] true if a job was enqueued
    def self.notify_later(order, result, notify_client: true)
      return false unless notifiable?(result)

      perform_later(order.tenant_id, result[:order_id], serialize_result(result), notify_client)
      true
    end

    # MWallet closed the unpaid invoice (winning :invoice_cancelled result of
    # MWallet::Service#sync_status / #process_callback): tell the customer
    #
    # @return [Boolean] true if a job was enqueued
    def self.notify_invoice_cancelled_later(order, result)
      return false unless result.to_h[:invoice_cancelled] && result[:order_id].present?

      perform_later(order.tenant_id, result[:order_id], { invoice_cancelled: true }, true)
      true
    end

    # Job arguments must be plain values: BigDecimal amounts / Symbols become Integers / Strings
    def self.serialize_result(result)
      result.to_h.slice(*RESULT_KEYS).compact.transform_values do |value|
        case value
        when BigDecimal then value.frac.zero? ? value.to_i : value.to_s("F")
        when Symbol then value.to_s
        else value
        end
      end
    end

    def perform_in_tenant(order_id, result, notify_client = true)
      order = Order.find_by(id: order_id)
      return AppLog.error("Cannot send payment notifications: order not found", order_id: order_id) unless order

      notifier = Notifier.for(ActsAsTenant.current_tenant)
      return notify_invoice_cancelled(notifier, order) if result[:invoice_cancelled] && !self.class.notifiable?(result)

      notifier.notify_payment_result(order, result, notify_client: notify_client)
      AppLog.info("Payment notifications sent", order_id: order.id, notify_barista: result[:notify_barista].present?,
                                                refund_required: result[:refund_required].present?,
                                                payment_error: result[:payment_error])
    end

    private

    def notify_invoice_cancelled(notifier, order)
      return unless order.status == OrderStatus::CANCELLED && order.last_notified_status != OrderStatus::CANCELLED

      return unless notifier.notify_order_cancelled(order, "Счёт аннулирован платёжной системой.")

      order.update_column(:last_notified_status, OrderStatus::CANCELLED)
    end
  end
end
