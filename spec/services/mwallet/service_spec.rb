# frozen_string_literal: true

require "rails_helper"

RSpec.describe MWallet::Service do
  subject(:service) { described_class.new(account) }

  let(:account) { current_tenant.payment_account }
  let(:create_response) do
    { "data" => { "invoice_id" => "INV-NEW", "paylink_url" => "https://pay.test/1", "emv_qr" => "https://qr.test/1.png",
                  "emv_qr_img" => "aGVsbG8=", "emv_qr_data" => "000201" } }
  end

  def new_order(total: 15_000)
    order = make_order(status: OrderStatus::NEW, invoice: nil, total: total)
    order.update_columns(payment_account_id: nil)
    order.reload
  end

  describe ".for_order" do
    it "uses the account the order's invoice was issued from" do
      order = make_order
      old = order.payment_account
      old.update!(active: false)
      PaymentAccount.create!(tenant: current_tenant, sid: "NEW", password: "p", base_url: PaymentAccount::TEST_BASE_URL)

      expect(described_class.for_order(order).payment_account).to eq(old)
    end

    it "falls back to the tenant's active account" do
      expect(described_class.for_order(new_order).payment_account).to eq(account)
    end

    it "passes client options (short timeouts for jobs)" do
      expect(described_class.for_order(make_order, timeout: 5, retry_count: 0).client)
        .to have_attributes(timeout: 5, retry_count: 0)
    end
  end

  describe "#create_invoice_for_order" do
    before { current_tenant.update!(order_expire_minutes: 20, name: "Кофейня Тест") }

    it "creates the invoice with the account's result_url and the shop's invoice lifetime" do
      order = new_order
      expect_any_instance_of(MWallet::Client).to receive(:create_invoice)
        .with(order_id: order.merchant_invoice_id, desc: "Заказ ##{order.id} - Кофейня Тест", amount: 15_000,
              currency: "KGS", result_url: account.callback_url, date_life: 20 * 60)
        .and_return(create_response)

      data = service.create_invoice_for_order(order)

      expect(data).to include(invoice_id: "INV-NEW", paylink_url: "https://pay.test/1", emv_qr_url: "https://qr.test/1.png",
                              qr_image_base64: "aGVsbG8=", emv_qr_data: "000201")
      expect(order.reload).to have_attributes(status: OrderStatus::INVOICE_CREATED, provider: "MWALLET",
                                              payment_account_id: account.id, invoice_id_provider: "INV-NEW",
                                              qr_url: "https://pay.test/1", emv_qr_url: "https://qr.test/1.png")
      expect(order.expires_at).to be_within(1.second).of(order.created_at + 20.minutes)
      expect(account.callback_url).to end_with("/pay/mwallet/#{account.id}")
    end

    it "schedules the status polling and the expiry at the payment deadline" do
      freeze_time
      order = new_order
      allow_any_instance_of(MWallet::Client).to receive(:create_invoice).and_return(create_response)

      service.create_invoice_for_order(order)

      expect(Payments::PollStatusJob).to have_been_enqueued.with(current_tenant.id, order.id, "INV-NEW", 0)
                                                           .at(5.seconds.from_now)
      expect(Payments::ExpireInvoiceJob).to have_been_enqueued.with(current_tenant.id, order.id)
                                                              .at(order.created_at + 20.minutes)
    end

    it "returns the existing invoice for an order that already has a live one (no second invoice)" do
      order = make_order(invoice: "INV-LIVE")
      order.update!(qr_url: "https://pay.test/live")
      expect_any_instance_of(MWallet::Client).not_to receive(:create_invoice)

      expect(service.create_invoice_for_order(order)).to include(invoice_id: "INV-LIVE", paylink_url: "https://pay.test/live")
      expect(enqueued_jobs).to be_empty
    end

    it "refuses an unpaid order whose payment time is over" do
      order = make_overdue(make_order(invoice: "INV-OLD"))
      expect_any_instance_of(MWallet::Client).not_to receive(:create_invoice)

      expect { service.create_invoice_for_order(order) }.to raise_error(Order::InvalidStatusTransition)
    end

    it "refuses orders that are paid or closed without calling MWallet" do
      expect_any_instance_of(MWallet::Client).not_to receive(:create_invoice)

      [ OrderStatus::PAID, OrderStatus::CANCELLED, OrderStatus::EXPIRED ].each_with_index do |status, i|
        order = make_order(status: status, invoice: "INV-S-#{i}")
        expect { service.create_invoice_for_order(order) }.to raise_error(Order::InvalidStatusTransition)
        expect(order.reload.status).to eq(status)
      end
    end

    it "moves a NEW order to ERROR and re-raises on a provider error" do
      order = new_order
      allow_any_instance_of(MWallet::Client).to receive(:create_invoice)
        .and_raise(MWalletError::BusinessError.new("SID 12345 invalid hash", code: 42))

      expect { service.create_invoice_for_order(order) }.to raise_error(MWalletError::BusinessError)

      expect(order.reload.status).to eq(OrderStatus::ERROR)
      expect(JSON.parse(order.raw_create_response)).to eq("error" => "SID 12345 invalid hash", "code" => 42)
      expect(enqueued_jobs).to be_empty
    end

    it "treats a response without invoice_id as an error" do
      order = new_order
      allow_any_instance_of(MWallet::Client).to receive(:create_invoice).and_return({ "data" => {} })

      expect { service.create_invoice_for_order(order) }.to raise_error(MWalletError::BusinessError, /no invoice_id/)
      expect(order.reload.status).to eq(OrderStatus::ERROR)
    end

    it "does not resurrect an order cancelled while the invoice was being created" do
      order = new_order
      allow_any_instance_of(MWallet::Client).to receive(:create_invoice) do
        Order.where(id: order.id).update_all(status: OrderStatus::CANCELLED) # the customer tapped "cancel"
        create_response
      end
      expect_any_instance_of(MWallet::Client).to receive(:cancel_invoice).with("INV-NEW").and_return({ "data" => { "success" => true } })

      expect { service.create_invoice_for_order(order) }.to raise_error(Order::InvalidStatusTransition)

      expect(order.reload).to have_attributes(status: OrderStatus::CANCELLED, invoice_id_provider: "INV-NEW")
      expect(Payments::LatePaymentCheckJob).to have_been_enqueued.with(current_tenant.id, order.id, 0)
      expect(Payments::PollStatusJob).not_to have_been_enqueued
    end

    it "refuses an order of another coffee shop" do
      order = new_order
      foreign = ActsAsTenant.with_tenant(other_tenant) { described_class.new(ActsAsTenant.current_tenant.payment_account) }

      expect { foreign.create_invoice_for_order(order) }.to raise_error(ArgumentError, /does not belong/)
    end
  end

  describe "#cancel_invoice_for_order" do
    it "cancels at MWallet, then locally, and schedules late-payment checks" do
      order = make_order(invoice: "INV-C")
      expect_any_instance_of(MWallet::Client).to receive(:cancel_invoice).with("INV-C")
                                                                         .and_return({ "data" => { "success" => true } })

      expect(service.cancel_invoice_for_order(order)).to be(true)

      expect(order.reload.status).to eq(OrderStatus::CANCELLED)
      expect(Payments::LatePaymentCheckJob).to have_been_enqueued.with(current_tenant.id, order.id, 0)
    end

    it "returns false but still cancels locally when MWallet refuses" do
      order = make_order(invoice: "INV-C")
      allow_any_instance_of(MWallet::Client).to receive(:cancel_invoice)
        .and_raise(MWalletError::BusinessError, "Команда не определена")

      expect(service.cancel_invoice_for_order(order)).to be(false)
      expect(order.reload.status).to eq(OrderStatus::CANCELLED)
      expect(Payments::LatePaymentCheckJob).to have_been_enqueued
    end

    it "returns false when MWallet answers without a confirmation" do
      order = make_order(invoice: "INV-C")
      allow_any_instance_of(MWallet::Client).to receive(:cancel_invoice).and_return({ "data" => {} })

      expect(service.cancel_invoice_for_order(order)).to be(false)
      expect(order.reload.status).to eq(OrderStatus::CANCELLED)
    end

    it "accepts a cancelled status as confirmation" do
      order = make_order(invoice: "INV-C")
      allow_any_instance_of(MWallet::Client).to receive(:cancel_invoice).and_return({ "data" => { "status" => "canceled" } })

      expect(service.cancel_invoice_for_order(order)).to be(true)
    end

    it "survives unexpected errors (the network kill switch here)" do
      order = make_order(invoice: "INV-C")

      expect(service.cancel_invoice_for_order(order)).to be(false)
      expect(order.reload.status).to eq(OrderStatus::CANCELLED)
    end

    it "does not overwrite an order paid in the meantime" do
      order = make_order(invoice: "INV-C")
      stale = stale_copy(order)
      order.mark_paid!(paid_amount: 15_000)
      allow_any_instance_of(MWallet::Client).to receive(:cancel_invoice).and_return({ "data" => { "success" => true } })

      service.cancel_invoice_for_order(stale)

      expect(order.reload.status).to eq(OrderStatus::PAID)
      expect(Payments::LatePaymentCheckJob).not_to have_been_enqueued
    end

    it "does nothing for orders without an invoice or already paid" do
      expect_any_instance_of(MWallet::Client).not_to receive(:cancel_invoice)

      expect(service.cancel_invoice_for_order(new_order)).to be(false)
      expect(service.cancel_invoice_for_order(make_order(status: OrderStatus::PAID, invoice: "INV-P"))).to be(false)
      expect(Order.where(status: OrderStatus::CANCELLED)).to be_empty
    end
  end

  describe "#sync_status" do
    it "returns an empty result for an order without an invoice" do
      expect(service.sync_status(new_order)).to eq(updated: false, order_id: nil, notify_barista: false)
    end

    it "keeps waiting on the real sandbox answer for an unpaid invoice" do
      order = make_order
      provider_returns("status" => "processing")

      expect(service.sync_status(order)).to eq(updated: false, order_id: order.id, notify_barista: false)
      expect(order.reload.status).to eq(OrderStatus::INVOICE_CREATED)
    end

    it "marks the order paid and stores the provider data (without the signature)" do
      order = make_order
      provider_returns("payments" => [ { "status" => "approved", "amount" => 15_000, "hash" => "sig" } ])

      expect(service.sync_status(order)).to eq(updated: true, order_id: order.id, notify_barista: true)

      payment = order.reload.payment
      expect(payment).to have_attributes(status: PaymentStatus::PAID, paid_amount: 15_000, invoice_id_provider: "INV-1")
      expect(JSON.parse(payment.raw_status_response)).to include("provider" => { "status" => "approved", "amount" => 15_000 },
                                                                 "previous_status" => OrderStatus::INVOICE_CREATED)
    end

    it "closes an invoice MWallet cancelled and schedules late-payment checks (winner only)" do
      order = make_order
      provider_returns("status" => "canceled")

      expect(service.sync_status(order)).to include(updated: true, invoice_cancelled: true)
      expect(service.sync_status(order)).to include(updated: false)
      expect(order.reload.status).to eq(OrderStatus::CANCELLED)
      expect(Payments::LatePaymentCheckJob).to have_been_enqueued.exactly(:once)
    end

    it "asks with the credentials of the order's own (older) account" do
      order = make_order(invoice: "INV-OLD-ACC")
      order.payment_account.update!(active: false, sid: "OLD")
      current = PaymentAccount.create!(tenant: current_tenant, sid: "NEW", password: "p", base_url: PaymentAccount::TEST_BASE_URL)
      sids = []
      allow_any_instance_of(MWallet::Client).to receive(:get_status) do |client, _id|
        sids << client.sid
        { "data" => { "status" => "processing" } }
      end

      described_class.new(current).sync_status(order)

      expect(sids).to eq([ "OLD" ])
    end
  end
end
