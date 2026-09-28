# frozen_string_literal: true

require "rails_helper"

RSpec.describe "MWallet callbacks (POST /pay/mwallet/:payment_account_id)", type: :request do
  let!(:account) { current_tenant.payment_account }

  def paid_body(invoice, amount: 15_000, **extra)
    signed_body({ "invoice_id" => invoice, "status" => 3, "amount" => amount, **extra })
  end

  describe "routing to the payment account" do
    it "returns 404 for an unknown account" do
      post "/pay/mwallet/999999", params: paid_body("INV-1"), headers: { "CONTENT_TYPE" => "application/json" }

      expect(response).to have_http_status(:not_found)
      expect(json_body).to eq("error" => "Not found")
    end

    it "returns 404 for a non-numeric account id" do
      post "/pay/mwallet/abc", params: paid_body("INV-1"), headers: { "CONTENT_TYPE" => "application/json" }

      expect(response).to have_http_status(:not_found)
    end

    it "processes the callback inside the account's coffee shop and logs it with the account" do
      order = make_order(invoice: "INV-OK")
      provider_confirms

      post_callback(paid_body("INV-OK", "order_id" => order.merchant_invoice_id))

      expect(response).to have_http_status(:ok)
      expect(json_body).to eq("status" => "ok")
      expect(order.reload.status).to eq(OrderStatus::PAID)
      log = CallbackLog.sole
      expect(log).to have_attributes(payment_account_id: account.id, tenant_id: current_tenant.id,
                                     invoice_id_provider: "INV-OK", merchant_invoice_id: order.merchant_invoice_id,
                                     verified_signature: true, processed: true, process_error: nil)
    end

    it "accepts a callback to an inactive (rotated) account and confirms it with that account's credentials" do
      order = make_order(invoice: "INV-ROTATED")
      account.update!(active: false, sid: "OLD-SID")
      PaymentAccount.create!(tenant: current_tenant, sid: "NEW-SID", password: "new-secret",
                             base_url: PaymentAccount::TEST_BASE_URL)
      asked_sids = []
      allow_any_instance_of(MWallet::Client).to receive(:get_status) do |client, invoice_id|
        asked_sids << [ client.sid, invoice_id ]
        { "data" => { "status" => "approved", "amount" => 15_000 } }
      end

      post_callback(paid_body("INV-ROTATED"), account: account)

      expect(response).to have_http_status(:ok)
      expect(order.reload.status).to eq(OrderStatus::PAID)
      expect(asked_sids).to eq([ [ "OLD-SID", "INV-ROTATED" ] ])
    end
  end

  describe "callbacks are triggers, confirmed with statusPayment" do
    it "leaves the order unpaid for a correctly signed paid callback while MWallet says processing" do
      order = make_order(invoice: "INV-EARLY")
      provider_returns("status" => "processing")
      body = paid_body("INV-EARLY")

      post_callback(body)

      expect(response).to have_http_status(:ok)
      expect(json_body).to eq("status" => "ok")
      expect(order.reload.status).to eq(OrderStatus::INVOICE_CREATED)
      expect(Payment.where(order_id: order.id)).to be_empty
      expect(CallbackLog.sole.process_error).to start_with("Not confirmed by statusPayment")
      expect(enqueued_jobs.map { |j| j["job_class"] }).not_to include("Payments::NotifyResultJob")

      # Not counted as handled: the provider's retry of the same body is checked again
      provider_confirms
      post_callback(body)
      expect(order.reload.status).to eq(OrderStatus::PAID)
    end

    it "marks the order PAID and notifies once when MWallet confirms" do
      order = make_order(invoice: "INV-CONFIRMED")
      provider_confirms

      2.times { |i| post_callback(paid_body("INV-CONFIRMED", "mktime" => i.to_s)) }
      perform_notifications

      expect(order.reload.status).to eq(OrderStatus::PAID)
      expect(texts_to(client_id).grep(/Оплата прошла успешно/).size).to eq(1)
      expect(texts_to(barista_id).grep(/Новый заказ ##{order.id}/).size).to eq(1)
    end

    it "changes nothing while MWallet is unreachable and leaves the payment to polling" do
      order = make_order(invoice: "INV-DOWN")
      allow_any_instance_of(Faraday::Connection).to receive(:post).and_raise(Faraday::ConnectionFailed, "refused")

      post_callback(paid_body("INV-DOWN"))

      expect(response).to have_http_status(:ok)
      expect(json_body).to eq("status" => "ok")
      expect(order.reload.status).to eq(OrderStatus::INVOICE_CREATED)
      expect(CallbackLog.sole.process_error).to eq("Confirmation failed: ProviderTimeout")

      provider_confirms
      Payments::PollStatusJob.perform_now(current_tenant.id, order.id, "INV-DOWN", 0)
      expect(order.reload.status).to eq(OrderStatus::PAID)
    end

    it "uses the amount reported by statusPayment, not the one in the callback" do
      order = make_order(total: 50_000, invoice: "INV-AMOUNT")
      provider_confirms(amount: 100)

      post_callback(paid_body("INV-AMOUNT", amount: 50_000))

      expect(order.reload.status).to eq(OrderStatus::ERROR)
      expect(order.payment.paid_amount).to eq(100)
    end

    it "checks the status for a non-paid callback too" do
      order = make_order(invoice: "INV-PENDING")
      provider_returns("status" => "processing")

      post_callback(signed_body({ "invoice_id" => "INV-PENDING", "status" => 1 }))

      expect(response).to have_http_status(:ok)
      expect(order.reload.status).to eq(OrderStatus::INVOICE_CREATED)
      expect(CallbackLog.sole).to have_attributes(processed: true, process_error: nil)
      expect(enqueued_jobs).to be_empty
    end
  end

  describe "request bodies" do
    it "returns 400 for an empty body" do
      post_callback("")
      expect(response).to have_http_status(:bad_request)
    end

    it "returns 400 for malformed JSON" do
      post_callback('{"invoice_id": ')
      expect(response).to have_http_status(:bad_request)
      expect(json_body).to eq("error" => "Invalid request body")
    end

    it "returns 400 for a JSON body that is not an object" do
      post_callback("[1, 2, 3]")
      expect(response).to have_http_status(:bad_request)
    end

    it "accepts a form-encoded callback (string values)" do
      order = make_order(invoice: "INV-FORM")
      provider_confirms
      params = signed_params({ "invoice_id" => "INV-FORM", "status" => "3", "amount" => "15000" })

      post_callback(URI.encode_www_form(params), content_type: "application/x-www-form-urlencoded")

      expect(response).to have_http_status(:ok)
      expect(order.reload.status).to eq(OrderStatus::PAID)
    end

    it "parses a JSON body sent with a form content type" do
      order = make_order(invoice: "INV-NOCT")
      provider_confirms

      post_callback(paid_body("INV-NOCT"), content_type: "application/x-www-form-urlencoded")

      expect(response).to have_http_status(:ok)
      expect(order.reload.status).to eq(OrderStatus::PAID)
    end
  end

  describe "signature" do
    before { provider_confirms }

    it "returns 401 for a forged signature and leaves the order alone" do
      order = make_order(invoice: "INV-FORGED")

      post_callback({ "invoice_id" => "INV-FORGED", "status" => 3, "hash" => "deadbeef" }.to_json)

      expect(response).to have_http_status(:unauthorized)
      expect(json_body).to eq("error" => "Invalid signature")
      expect(order.reload.status).to eq(OrderStatus::INVOICE_CREATED)
      expect(CallbackLog.sole.process_error).to eq("Invalid signature")
    end

    it "returns 401 for a callback without a signature" do
      post_callback({ "invoice_id" => "INV-X", "status" => 3 }.to_json)
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 401 when the signed body was tampered with" do
      order = make_order(total: 50_000, invoice: "INV-TAMPER")
      params = signed_params({ "invoice_id" => "INV-TAMPER", "status" => 3, "amount" => 100 })
      params["amount"] = 50_000

      post_callback(params.to_json)

      expect(response).to have_http_status(:unauthorized)
      expect(order.reload.status).to eq(OrderStatus::INVOICE_CREATED)
    end
  end

  describe "errors" do
    it "answers 200 with a generic status and never exposes exception details" do
      allow_any_instance_of(MWallet::Service).to receive(:process_callback)
        .and_raise(StandardError, "PG::Secret orders.raw_create_response")

      post_callback(paid_body("INV-ERR"))

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Secret")
      expect(json_body).to eq("status" => "error")
    end

    it "acknowledges a callback for an unknown invoice with 200" do
      post_callback(paid_body("INV-UNKNOWN"))

      expect(response).to have_http_status(:ok)
      expect(json_body).to eq("status" => "ok")
      expect(CallbackLog.sole.process_error).to eq("Order not found")
      expect(enqueued_jobs).to be_empty
    end
  end

  describe "notifications" do
    it "enqueues the payment notifications for the winning callback only (never inline)" do
      order = make_order(invoice: "INV-NOTIFY")
      provider_confirms

      expect { post_callback(paid_body("INV-NOTIFY")) }
        .to have_enqueued_job(Payments::NotifyResultJob)
        .with(current_tenant.id, order.id, hash_including(notify_barista: true), true).exactly(:once)
      expect(api.calls).to be_empty

      # The provider repeats the callback with another body: the order is already PAID
      expect { post_callback(paid_body("INV-NOTIFY", "mktime" => "2")) }.not_to have_enqueued_job(Payments::NotifyResultJob)

      perform_notifications
      expect(texts_to(client_id).join).to include("Оплата прошла успешно")
      expect(texts_to(barista_id).join).to include("Новый заказ ##{order.id}")
    end

    it "tells the customer once when the check shows MWallet closed the invoice" do
      order = make_order(invoice: "INV-CLOSED")
      provider_returns("status" => "canceled")

      2.times { |i| post_callback(signed_body({ "invoice_id" => "INV-CLOSED", "status" => 2, "mktime" => i.to_s })) }
      perform_notifications

      expect(order.reload).to have_attributes(status: OrderStatus::CANCELLED, last_notified_status: OrderStatus::CANCELLED)
      expect(texts_to(client_id).grep(/Счёт аннулирован платёжной системой/).size).to eq(1)
    end
  end
end
