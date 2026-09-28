# frozen_string_literal: true

module MiniApp
  # An order of the customer, as the Mini App shows it (status screen, "Мои заказы")
  class OrderPresenter
    # @param order [Order]
    # @param time_zone [ActiveSupport::TimeZone] the coffee shop's zone, for the timestamps
    def initialize(order, time_zone:)
      @order = order
      @time_zone = time_zone
    end

    def as_json(*)
      {
        id: @order.id,
        status: @order.status,
        status_text: @order.display_status,
        created_at: timestamp(@order.created_at),
        items: @order.order_items.map { |item| { name: item.item_name, qty: item.qty, line_total: item.line_total } },
        total: @order.total_amount,
        comment: @order.comment,
        payment: payment_json,
        refund_required: @order.payment&.status == PaymentStatus::REFUND_REQUIRED,
        can_cancel: OrderService::CLIENT_CANCELLABLE.include?(@order.status)
      }
    end

    private

    # How to pay, only while the invoice is open
    def payment_json
      return nil unless @order.status == OrderStatus::INVOICE_CREATED

      {
        app_url: @order.payment_app_url,
        paylink_url: @order.qr_url,
        qr_image_url: @order.emv_qr_url,
        expires_at: timestamp(@order.payment_deadline)
      }
    end

    def timestamp(time) = time&.in_time_zone(@time_zone)&.iso8601
  end
end
