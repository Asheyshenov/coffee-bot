# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Payments: paid amount verification" do
  def poll(order) = Payments::PollStatusJob.perform_now(current_tenant.id, order.id)

  describe "partial payment via polling" do
    it "moves the order to ERROR and alerts baristas exactly once" do
      order = make_order(total: 50_000)
      stub_provider_status(status: "approved", amount: "100")

      2.times { poll(order) } # a second poll must not alert again
      2.times { Payments::NotifyResultJob.notify_later(order, mwallet_service.sync_status(order)) }
      perform_notifications

      expect(order.reload.status).to eq(OrderStatus::ERROR)
      alerts = texts_to(barista_id).grep(/⚠️ Проблема с оплатой заказа ##{order.id}/)
      expect(alerts.size).to eq(1)
      expect(alerts.first).to include("500.00 KGS", "1.00 KGS")
      expect(texts_to(client_id)).to be_empty
    end

    it "stores the explanation and the actually paid amount" do
      order = make_order(total: 50_000)
      stub_provider_status(status: "approved", amount: 100)

      mwallet_service.sync_status(order)

      expect(order.reload.invoice_status_raw).to include("AMOUNT_MISMATCH", "50000", "100")
      expect(order.payment).to have_attributes(status: PaymentStatus::FAILED, paid_amount: 100)
    end

    it "logs an error with order id, expected and received amount" do
      order = make_order(total: 50_000)
      stub_provider_status(status: "approved", amount: 100)
      allow(AppLog).to receive(:error).and_call_original

      mwallet_service.sync_status(order)

      expect(AppLog).to have_received(:error)
        .with("Paid amount is less than order total, order moved to ERROR", hash_including(order_id: order.id, expected: 50_000, got: 100))
    end

    it "returns a payment_error result without notify_barista" do
      order = make_order(total: 50_000)
      stub_provider_status(status: "approved", amount: 100)

      result = mwallet_service.sync_status(order)

      expect(result).to include(updated: true, order_id: order.id, notify_barista: false, payment_error: :amount_mismatch,
                                expected_amount: 50_000, paid_amount: BigDecimal("100"))
    end
  end

  describe "accepted amounts" do
    {
      "exact Integer" => 15_000,
      "numeric String" => "15000",
      "decimal String" => "15000.00",
      "overpayment" => "20000"
    }.each do |label, amount|
      it "marks the order PAID for #{label} (#{amount.inspect})" do
        order = make_order(total: 15_000)
        stub_provider_status(status: "approved", amount: amount)

        result = mwallet_service.sync_status(order)

        expect(result).to include(updated: true, notify_barista: true)
        expect(order.reload.status).to eq(OrderStatus::PAID)
      end
    end

    it 'rejects an amount one tyiyn short ("14999.99")' do
      order = make_order(total: 15_000)
      stub_provider_status(status: "approved", amount: "14999.99")

      mwallet_service.sync_status(order)

      expect(order.reload.status).to eq(OrderStatus::ERROR)
    end

    it "rejects an unparseable amount instead of guessing" do
      order = make_order(total: 15_000)
      stub_provider_status(status: "approved", amount: "abc")

      result = mwallet_service.sync_status(order)

      expect(result).to include(payment_error: :amount_unparseable)
      expect(order.reload.status).to eq(OrderStatus::ERROR)
    end

    it "accepts a payment without any amount but logs a warning" do
      order = make_order(total: 15_000)
      stub_provider_status(status: "approved")
      allow(AppLog).to receive(:warn).and_call_original

      mwallet_service.sync_status(order)

      expect(order.reload.status).to eq(OrderStatus::PAID)
      expect(AppLog).to have_received(:warn)
        .with("Provider reported payment without amount, accepting it", hash_including(order_id: order.id))
    end
  end

  describe "partial payment via callback", type: :request do
    it "does not mark PAID and alerts baristas once even if the callback is repeated" do
      order = make_order(total: 50_000, invoice: "INV-PART")
      stub_provider_status(status: "approved", amount: 100)

      2.times do |i|
        post_callback(signed_body({ "invoice_id" => "INV-PART", "status" => 3, "amount" => 100, "mktime" => i.to_s }))
        expect(response).to have_http_status(:ok)
      end
      perform_notifications

      expect(order.reload.status).to eq(OrderStatus::ERROR)
      expect(texts_to(barista_id).grep(/⚠️ Проблема с оплатой/).size).to eq(1)
    end
  end
end
