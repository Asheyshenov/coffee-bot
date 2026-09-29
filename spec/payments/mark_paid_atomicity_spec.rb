# frozen_string_literal: true

require "rails_helper"

# Concurrency is simulated with stale model instances: every "worker" loaded the order
# while it was INVOICE_CREATED (transactional tests share one connection, so real
# threads can't overlap inside a transaction).
RSpec.describe "Payments: atomic status transitions" do
  describe "callback vs polling race" do
    it "notifies only once when the callback and the polling both see the payment" do
      order = make_order(invoice: "INV-RACE")
      stale_for_poller = stale_copy(order)
      provider_confirms
      params = signed_params({ "invoice_id" => "INV-RACE", "status" => 3, "amount" => 15_000 })

      callback_result = mwallet_service.process_callback(params, params.to_json)
      poll_result = mwallet_service.sync_status(stale_for_poller)
      [ callback_result, poll_result ].each { |result| Payments::NotifyResultJob.notify_later(order, result) }
      perform_notifications

      expect(callback_result).to include(success: true, confirmed: true, updated: true, notify_barista: true)
      expect(poll_result).to include(updated: false, notify_barista: false)
      expect(texts_to(client_id).grep(/Оплата прошла успешно/).size).to eq(1)
      expect(texts_to(barista_id).grep(/Новый заказ ##{order.id}/).size).to eq(1)
    end

    it 'a stale "rejected" poll does not cancel an order paid meanwhile via callback' do
      order = make_order(invoice: "INV-STALE")
      stale_for_poller = stale_copy(order)
      provider_confirms
      params = signed_params({ "invoice_id" => "INV-STALE", "status" => 3, "amount" => 15_000 })
      mwallet_service.process_callback(params, params.to_json)

      # The poller's statusPayment snapshot still shows only the declined first attempt
      stub_provider_status(status: "rejected", amount: 15_000)
      result = mwallet_service.sync_status(stale_for_poller)

      expect(result).to include(updated: false, notify_barista: false)
      expect(order.reload.status).to eq(OrderStatus::PAID)
      expect(Payment.where(order_id: order.id).pluck(:status)).to eq([ PaymentStatus::PAID ])
    end

    it 'a provider "cancelled" status never moves a PAID order' do
      order = make_order
      order.mark_paid!(paid_amount: 15_000)
      stub_provider_status(status: "cancelled")

      expect(mwallet_service.sync_status(order)).to include(updated: false)
      expect(order.reload.status).to eq(OrderStatus::PAID)
    end

    it 'a provider "cancelled" invoice status still closes an unpaid invoice' do
      order = make_order
      # An invoice closed at MWallet reports it in data.status (a declined attempt in
      # data.payments[] keeps the invoice open)
      provider_returns("status" => "cancelled")

      expect(mwallet_service.sync_status(order)).to include(updated: true, notify_barista: false)
      expect(order.reload.status).to eq(OrderStatus::CANCELLED)
    end

    it "the expiry loses against a payment committed a moment earlier" do
      order = make_order
      stale_for_expiry = stale_copy(order)

      expect(order.mark_paid!(paid_amount: 15_000)).to be(true)
      expect(stale_for_expiry.expire!).to be(false)
      expect(order.reload.status).to eq(OrderStatus::PAID)
    end
  end
end
