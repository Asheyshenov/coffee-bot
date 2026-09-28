# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Payments: late payments (after EXPIRED / CANCELLED)" do
  describe "via callback", type: :request do
    before { provider_confirms }

    def post_paid_callback(invoice, amount: 15_000)
      post_callback(signed_body({ "invoice_id" => invoice, "status" => 3, "amount" => amount }))
      perform_notifications
    end

    it "does not fulfil a payment for an EXPIRED order: records a refund, tells client and baristas" do
      order = make_order(status: OrderStatus::EXPIRED, invoice: "INV-LATE-1")

      post_paid_callback("INV-LATE-1")

      expect(response).to have_http_status(:ok)
      expect(order.reload.status).to eq(OrderStatus::EXPIRED)
      expect(Payment.where(order_id: order.id, status: PaymentStatus::REFUND_REQUIRED).count).to eq(1)
      expect(order.refund_required?).to be(true)

      client_text = texts_to(client_id).join
      expect(client_text).to include("Оплата по заказу ##{order.id} поступила после истечения срока счёта", "деньги вернём")
      expect(client_text).not_to include("передан в работу")
      barista_text = texts_to(barista_id).join
      expect(barista_text).to include("Требуется возврат по заказу ##{order.id}", "INV-LATE-1", "150.00 KGS")
      expect(barista_text).not_to include("Новый заказ")
      refund_button = api.messages_to(barista_id).last[:reply_markup].inline_keyboard.flatten.first
      expect(refund_button.callback_data).to eq("refund_done_#{order.id}")
    end

    it 'records a refund for a CANCELLED order with a "после отмены" reason' do
      order = make_order(status: OrderStatus::CANCELLED, invoice: "INV-LATE-2")

      post_paid_callback("INV-LATE-2")

      expect(order.reload.status).to eq(OrderStatus::CANCELLED)
      expect(texts_to(barista_id).join).to include("Клиент оплатил после отмены заказа")
    end

    it "refunds whatever was paid for a late payment, even below the total" do
      order = make_order(status: OrderStatus::EXPIRED, total: 50_000, invoice: "INV-LATE-3")
      provider_confirms(amount: 100)

      post_paid_callback("INV-LATE-3", amount: 100)

      expect(order.reload.status).to eq(OrderStatus::EXPIRED)
      expect(order.payment.paid_amount).to eq(100)
      expect(texts_to(barista_id).join).to include("Оплачено: 1.00 KGS")
    end

    it "requests the refund only once when the provider repeats the callback" do
      order = make_order(status: OrderStatus::EXPIRED, invoice: "INV-LATE-5")

      post_paid_callback("INV-LATE-5")
      post_callback(signed_body({ "invoice_id" => "INV-LATE-5", "status" => "3", "amount" => "15000.00" }))
      perform_notifications

      expect(Payment.where(order_id: order.id).count).to eq(1)
      expect(texts_to(barista_id).join.scan("Требуется возврат").size).to eq(1)
    end

    it "never resurrects an order that was paid and then refunded" do
      order = make_order(status: OrderStatus::CANCELLED, invoice: "INV-LATE-4")
      Payment.create!(order: order, invoice_id_provider: "INV-LATE-4", paid_amount: 15_000, status: PaymentStatus::REFUNDED_FULL)

      post_paid_callback("INV-LATE-4")

      expect(order.reload.status).to eq(OrderStatus::CANCELLED)
      expect(order.payment.status).to eq(PaymentStatus::REFUNDED_FULL)
      expect(api.calls).to be_empty
    end
  end

  describe "via polling" do
    it "sync_status reports a required refund for an EXPIRED order" do
      order = make_order(status: OrderStatus::EXPIRED)
      stub_provider_status(status: "approved", amount: 15_000)

      result = mwallet_service.sync_status(order)

      expect(result).to include(updated: true, order_id: order.id, notify_barista: false, late_payment: true,
                                refund_required: true, previous_status: OrderStatus::EXPIRED, paid_amount: 15_000)
      expect(order.reload.status).to eq(OrderStatus::EXPIRED)
    end

    it "prefers an approved payment over an earlier rejected attempt" do
      order = make_order(status: OrderStatus::EXPIRED)
      provider_returns("payments" => [ { "status" => "rejected", "amount" => "15000" },
                                       { "status" => "approved", "amount" => "15000" } ])

      mwallet_service.sync_status(order)

      expect(order.refund_required?).to be(true)
    end

    it "turns a payment that loses the race against the expiry into a refund" do
      order = make_order(invoice: "INV-RACE") # INVOICE_CREATED in memory
      stub_provider_status(status: "approved", amount: 15_000)
      Order.where(id: order.id).update_all(status: OrderStatus::EXPIRED) # expiry got there first

      result = mwallet_service.sync_status(order)

      expect(result).to include(updated: true, refund_required: true, previous_status: OrderStatus::EXPIRED)
      expect(order.reload.status).to eq(OrderStatus::EXPIRED)
      expect(order.payment.status).to eq(PaymentStatus::REFUND_REQUIRED)
    end
  end

  describe "refund done by staff" do
    it "closes the refund once and tells the client" do
      order = make_order(status: OrderStatus::EXPIRED)
      order.record_late_payment!(paid_amount: 15_000)

      expect(order.mark_refunded!(barista_id)).to be(true)
      expect(order.mark_refunded!(barista_id)).to be(false)
      Notifier.for(current_tenant).notify_refund_completed(order)

      expect(order.reload.payment.status).to eq(PaymentStatus::REFUNDED_FULL)
      expect(order.payment_operations.sole).to have_attributes(operation_type: PaymentOperationType::REFUND, amount: 15_000)
      expect(texts_to(client_id).join).to include("Деньги за заказ ##{order.id} возвращены")
      expect(Payments::LatePaymentCheckJob.candidate?(order)).to be(false)
    end
  end
end
