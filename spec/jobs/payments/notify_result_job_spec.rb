# frozen_string_literal: true

require "rails_helper"

RSpec.describe Payments::NotifyResultJob do
  describe ".notify_later" do
    it "enqueues nothing for results that changed nothing" do
      order = make_order

      [
        { updated: false, order_id: order.id, notify_barista: false },
        { updated: true, order_id: order.id, notify_barista: false },
        { updated: true, order_id: nil, notify_barista: true },
        {}
      ].each { |result| expect(described_class.notify_later(order, result)).to be(false) }

      expect(enqueued_jobs).to be_empty
    end

    it "enqueues a winning result with plain job arguments" do
      order = make_order(total: 50_000)
      result = { updated: true, order_id: order.id, notify_barista: false, payment_error: :amount_mismatch,
                 expected_amount: 50_000, paid_amount: BigDecimal("14999.99") }

      expect(described_class.notify_later(order, result)).to be(true)

      expect(described_class).to have_been_enqueued.with(
        current_tenant.id, order.id,
        { order_id: order.id, notify_barista: false, payment_error: "amount_mismatch", expected_amount: 50_000,
          paid_amount: "14999.99" },
        true
      )
    end

    it "passes notify_client through" do
      order = make_order

      described_class.notify_later(order, { order_id: order.id, notify_barista: true }, notify_client: false)

      expect(described_class).to have_been_enqueued.with(current_tenant.id, order.id, hash_including(notify_barista: true), false)
    end
  end

  describe "#perform" do
    it "sends the payment problem alert with the amounts" do
      order = make_order(total: 50_000)

      described_class.notify_later(order, { order_id: order.id, payment_error: :amount_mismatch, expected_amount: 50_000,
                                            paid_amount: BigDecimal("100") })
      perform_notifications

      expect(texts_to(barista_id).join).to include("Проблема с оплатой заказа ##{order.id}", "500.00 KGS", "1.00 KGS")
      expect(texts_to(client_id)).to be_empty
    end

    it "sends a refund request with the paid amount and previous status" do
      order = make_order(status: OrderStatus::CANCELLED, invoice: "INV-R")

      described_class.notify_later(order, { order_id: order.id, refund_required: true, late_payment: true,
                                            previous_status: OrderStatus::CANCELLED, paid_amount: 12_000 })
      perform_notifications

      expect(texts_to(barista_id).join).to include("Клиент оплатил после отмены заказа", "120.00 KGS", "INV-R")
      expect(texts_to(client_id).join).to include("поступила после отмены заказа")
    end

    it "logs and skips an order that is gone" do
      expect { described_class.perform_now(current_tenant.id, 0, { notify_barista: true }, true) }.not_to raise_error
      expect(api.calls).to be_empty
    end

    it "tells the customer about an invoice closed by MWallet only once" do
      order = make_order(status: OrderStatus::CANCELLED)

      2.times { described_class.notify_invoice_cancelled_later(order, { order_id: order.id, invoice_cancelled: true }) }
      perform_notifications

      expect(texts_to(client_id).grep(/Счёт аннулирован/).size).to eq(1)
      expect(order.reload.last_notified_status).to eq(OrderStatus::CANCELLED)
    end
  end
end
