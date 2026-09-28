# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Payments: MWallet callback deduplication" do
  describe "callback endpoint", type: :request do
    before { provider_confirms }

    it "ignores an identical repeated callback body (processed once, notified once)" do
      order = make_order(invoice: "INV-DUP")
      body = signed_body({ "invoice_id" => "INV-DUP", "status" => 3, "amount" => 15_000 })

      2.times do
        post_callback(body)
        expect(response).to have_http_status(:ok)
        expect(json_body).to eq("status" => "ok")
      end
      perform_notifications

      expect(order.reload.status).to eq(OrderStatus::PAID)
      logs = CallbackLog.where(invoice_id_provider: "INV-DUP").order(:id)
      expect(logs.map(&:process_error)).to eq([ nil, CallbackLog::DUPLICATE_ERROR ])
      expect(logs.map(&:event_id)).to all(be_nil)
      expect(texts_to(client_id).size).to eq(1)
      expect(texts_to(barista_id).size).to eq(1)
    end

    it "does not even ask MWallet again for a duplicate" do
      make_order(invoice: "INV-DUP2")
      body = signed_body({ "invoice_id" => "INV-DUP2", "status" => 3, "amount" => 15_000 })
      post_callback(body)

      expect_any_instance_of(MWallet::Client).not_to receive(:get_status)
      post_callback(body)
    end

    it "processes a provider retry of the same body after a failed attempt" do
      order = make_order(invoice: "INV-RETRY")
      body = signed_body({ "invoice_id" => "INV-RETRY", "status" => 3, "amount" => 15_000 })
      calls = 0
      allow_any_instance_of(Order).to receive(:mark_paid!).and_wrap_original do |original, *args, **kwargs|
        calls += 1
        raise ActiveRecord::StatementInvalid, "deadlock detected" if calls == 1

        original.call(*args, **kwargs)
      end

      post_callback(body)
      expect(json_body).to eq("status" => "error")
      expect(order.reload.status).to eq(OrderStatus::INVOICE_CREATED)
      expect(CallbackLog.sole.process_error).to include("deadlock detected")

      post_callback(body)
      expect(order.reload.status).to eq(OrderStatus::PAID)
    end

    it "does not count callbacks with an invalid signature as handled" do
      make_order(invoice: "INV-SIG")
      forged = { "invoice_id" => "INV-SIG", "status" => 3, "hash" => "deadbeef" }.to_json

      post_callback(forged)

      expect(response).to have_http_status(:unauthorized)
      expect(CallbackLog.duplicate?(nil, "INV-SIG", forged)).to be(false)
    end
  end

  # A callback is a duplicate only if an identical one (same provider event id, or
  # same raw body for the same invoice) was already verified AND processed.
  describe CallbackLog do
    def handled_log(**attrs)
      CallbackLog.log_callback(payment_account: current_tenant.payment_account, **attrs).tap do |log|
        log.mark_verified!
        log.mark_processed!
      end
    end

    it "detects the same event id, or the same body for the same invoice" do
      handled_log(event_id: "EVT-001", invoice_id: "INV-123", raw_body: '{"status":"PAID"}')

      expect(CallbackLog.duplicate?("EVT-001", "INV-123", '{"status":"PAID"}')).to be(true)
      expect(CallbackLog.duplicate?(nil, "INV-123", '{"status":"PAID"}')).to be(true)
    end

    it "allows a new body for the same invoice (pending -> paid)" do
      handled_log(event_id: "EVT-001", invoice_id: "INV-123", raw_body: '{"status":1}')

      expect(CallbackLog.duplicate?("EVT-002", "INV-123", '{"status":3}')).to be(false)
      expect(CallbackLog.duplicate?(nil, "INV-123", '{"status":3}')).to be(false)
      expect(CallbackLog.duplicate?(nil, "INV-456", '{"status":1}')).to be(false)
    end

    it "does not treat unprocessed or failed callbacks as duplicates (provider retry is processed)" do
      account = current_tenant.payment_account
      CallbackLog.log_callback(payment_account: account, invoice_id: "INV-123", raw_body: '{"status":3}').mark_verified!
      failed = CallbackLog.log_callback(payment_account: account, invoice_id: "INV-123", raw_body: '{"status":3}')
      failed.mark_verified!
      failed.mark_failed!("database is locked")

      expect(CallbackLog.duplicate?(nil, "INV-123", '{"status":3}')).to be(false)
    end

    it "logs several callbacks for the same invoice without a unique conflict" do
      2.times { handled_log(invoice_id: "INV-123", raw_body: '{"status":1}') }

      expect(CallbackLog.where(invoice_id_provider: "INV-123").count).to eq(2)
    end

    it "does not see handled callbacks of another coffee shop" do
      ActsAsTenant.with_tenant(other_tenant) do
        CallbackLog.log_callback(payment_account: current_tenant.payment_account, invoice_id: "INV-X",
                                 raw_body: "{}").then { |l| l.update!(verified_signature: true, processed: true) }
      end

      expect(CallbackLog.duplicate?(nil, "INV-X", "{}")).to be(false)
    end
  end
end
