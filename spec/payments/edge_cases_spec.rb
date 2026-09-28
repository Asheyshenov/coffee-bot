# frozen_string_literal: true

require "rails_helper"

# Payment groups of the legacy edge-case audit. Every example asserts the expected
# behaviour, so a failing example is a bug.
RSpec.describe "Payments: edge cases audit" do
  describe "MWallet callback", type: :request do
    it "marks an INVOICE_CREATED order as PAID on a valid signed callback confirmed by MWallet" do
      order = make_order(invoice: "INV-CB-1")
      provider_confirms

      post_callback(signed_body({ "invoice_id" => "INV-CB-1", "order_id" => order.merchant_invoice_id, "status" => 3,
                                  "amount" => 15_000 }))

      expect(order.reload.status).to eq(OrderStatus::PAID)
    end

    it "accepts a second callback for the same invoice (pending -> paid)" do
      order = make_order(invoice: "INV-CB-2")
      provider_returns("status" => "processing")
      post_callback(signed_body({ "invoice_id" => "INV-CB-2", "status" => 1 }))

      provider_confirms
      post_callback(signed_body({ "invoice_id" => "INV-CB-2", "status" => 3, "amount" => 15_000 }))

      expect(json_body).to eq("status" => "ok")
      expect(order.reload.status).to eq(OrderStatus::PAID)
    end

    it "does NOT mark as paid when the paid amount is less than the order total" do
      order = make_order(invoice: "INV-CB-3", total: 50_000)
      provider_confirms(amount: 100)

      post_callback(signed_body({ "invoice_id" => "INV-CB-3", "status" => 3, "amount" => 100 }))

      expect(order.reload.status).to eq(OrderStatus::ERROR)
    end

    it "rejects a callback with a forged signature (401)" do
      order = make_order(invoice: "INV-CB-4")

      post_callback({ "invoice_id" => "INV-CB-4", "status" => 3, "hash" => "deadbeef" }.to_json)

      expect(response).to have_http_status(:unauthorized)
      expect(order.reload.status).to eq(OrderStatus::INVOICE_CREATED)
    end

    it "does not leak internal exception messages in the response body" do
      allow_any_instance_of(MWallet::Service).to receive(:process_callback).and_raise(StandardError, "PG::Secret table xyz")

      post_callback("{}")

      expect(response.body).not_to include("PG::Secret")
    end

    it "handles an empty body without a 500" do
      post_callback("")

      expect(response.status).to be < 500
    end

    it "notifies the CLIENT (not only baristas) when paid via callback" do
      make_order(invoice: "INV-CB-5")
      provider_confirms

      post_callback(signed_body({ "invoice_id" => "INV-CB-5", "status" => 3, "amount" => 15_000 }))
      perform_notifications

      expect(api.of(:send_message).map { |m| m[:chat_id] }).to include(client_id, barista_id)
    end
  end

  describe "polling" do
    it "does NOT mark as paid when the provider reports a smaller amount than the total" do
      order = make_order(total: 50_000)
      stub_provider_status(status: "approved", amount: 100)

      mwallet_service.sync_status(order)

      expect(order.reload.status).not_to eq(OrderStatus::PAID)
    end

    it "detects a payment that arrived after the order was expired (money taken, order dead)" do
      order = make_order(status: OrderStatus::EXPIRED)
      stub_provider_status(status: "approved", amount: 15_000)

      expect(mwallet_service.sync_status(order)[:updated]).to be(true)
    end
  end

  describe "jobs wiring" do
    it "schedules the payments sweep every minute (safety net for lost expiry jobs)" do
      config = ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/recurring.yml"))

      %w[production development].each do |env|
        expect(config.dig(env, "payments_sweep")).to include("class" => "Payments::SweepJob", "schedule" => "every minute")
      end
    end

    it "expired orders end in EXPIRED status and the client gets a message" do
      order = make_overdue(make_order)
      allow_any_instance_of(MWallet::Client).to receive(:cancel_invoice).and_return({ "data" => { "success" => true } })

      Payments::ExpireInvoiceJob.perform_now(current_tenant.id, order.id)

      expect(order.reload.status).to eq(OrderStatus::EXPIRED)
      expect(api.of(:send_message).map { |m| m[:chat_id] }).to include(client_id)
    end

    it "an unpaid order whose expiry job was lost is expired by the sweep" do
      order = make_overdue(make_order)
      allow_any_instance_of(MWallet::Client).to receive(:cancel_invoice).and_return({ "data" => { "success" => true } })

      Payments::SweepJob.perform_now

      expect(order.reload.status).to eq(OrderStatus::EXPIRED)
    end
  end

  describe "data integrity" do
    it "logs order status transitions with the correct from status" do
      order = make_order(status: OrderStatus::NEW)
      allow(AppLog).to receive(:info).and_call_original

      order.transition_to!(OrderStatus::INVOICE_CREATED)

      expect(AppLog).to have_received(:info)
        .with("Order status changed", order_id: order.id, from: OrderStatus::NEW, to: OrderStatus::INVOICE_CREATED)
    end

    it "the status column rejects values outside OrderStatus::ALL" do
      order = make_order

      expect { ActiveRecord::Base.transaction(requires_new: true) { order.update_column(:status, "cancelled") } }
        .to raise_error(ActiveRecord::StatementInvalid)
    end
  end
end
