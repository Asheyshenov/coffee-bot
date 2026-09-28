# frozen_string_literal: true

require "rails_helper"

# Merchants differ: some return text statuses ("approved", "processing"), others
# numeric codes, and the status may sit in data.status or in data.payments[].
RSpec.describe "Payments: provider status formats" do
  describe "statusPayment" do
    it 'keeps waiting on the real sandbox response for an unpaid invoice ({"status":"processing"})' do
      order = make_order
      provider_returns("status" => "processing")

      result = mwallet_service.sync_status(order)

      expect(result[:updated]).to be(false)
      expect(order.reload.status).to eq(OrderStatus::INVOICE_CREATED)
    end

    {
      "text in data.status" => { "status" => "approved", "amount" => 15_000 },
      "code in data.status" => { "status" => 3, "amount" => 15_000 },
      "numeric string in data.status" => { "status" => "3", "amount" => "15000" },
      "numeric string in data.payments[]" => { "payments" => [ { "status" => "3", "amount" => "15000" } ] }
    }.each do |label, data|
      it "marks the order paid for #{label}" do
        order = make_order
        provider_returns(data)

        mwallet_service.sync_status(order)

        expect(order.reload.status).to eq(OrderStatus::PAID)
      end
    end

    it "cancels an unpaid invoice for code 2 sent as a string" do
      order = make_order
      provider_returns("status" => "2")

      mwallet_service.sync_status(order)

      expect(order.reload.status).to eq(OrderStatus::CANCELLED)
    end

    it "ignores an unknown status and logs the raw value" do
      order = make_order
      provider_returns("status" => "on_hold_by_bank")
      allow(AppLog).to receive(:warn).and_call_original

      result = mwallet_service.sync_status(order)

      expect(result[:updated]).to be(false)
      expect(order.reload.status).to eq(OrderStatus::INVOICE_CREATED)
      expect(AppLog).to have_received(:warn)
        .with("Unknown MWallet payment status, ignoring", hash_including(provider_status: '"on_hold_by_bank"'))
    end

    it "ignores malformed payment entries" do
      order = make_order
      provider_returns("payments" => [ "garbage", nil ], "status" => "processing")

      expect(mwallet_service.sync_status(order)[:updated]).to be(false)
    end
  end

  describe "callback", type: :request do
    it 'accepts a numeric-string status code ("3")' do
      order = make_order(invoice: "INV-FMT-1")
      provider_returns("status" => "3", "amount" => "15000")

      post_callback(signed_body({ "invoice_id" => "INV-FMT-1", "status" => "3", "amount" => "15000" }))

      expect(order.reload.status).to eq(OrderStatus::PAID)
    end

    it 'accepts a text status ("approved")' do
      order = make_order(invoice: "INV-FMT-2")
      provider_returns("status" => "approved", "amount" => 15_000)

      post_callback(signed_body({ "invoice_id" => "INV-FMT-2", "status" => "approved", "amount" => 15_000 }))

      expect(order.reload.status).to eq(OrderStatus::PAID)
    end
  end
end
