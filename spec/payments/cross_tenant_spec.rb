# frozen_string_literal: true

require "rails_helper"

# Every coffee shop has its own MWallet merchant account and result_url. A callback
# must never reach another shop's orders, whatever it carries.
RSpec.describe "Payments: tenant isolation", type: :request do
  let(:shop_a) { current_tenant }
  let(:account_a) { shop_a.payment_account }
  let!(:shop_b) { other_tenant(slug: "shop-b", barista_ids: [ 4004 ]) }
  let(:account_b) { shop_b.payment_account }
  let(:shop_b_secret) { "shop-b-secret" }

  before do
    account_b.update!(password: shop_b_secret)
    provider_confirms
  end

  def in_shop_b(&block) = ActsAsTenant.with_tenant(shop_b, &block)

  def paid_callback(invoice, secret: TenancyHelpers::MWALLET_SECRET)
    signed_body({ "invoice_id" => invoice, "status" => 3, "amount" => 15_000 }, secret: secret)
  end

  it "a callback to shop A's account never touches shop B's order with the same invoice id" do
    order_a = make_order(invoice: "INV-SAME")
    order_b = in_shop_b { make_order(invoice: "INV-SAME") }

    post_callback(paid_callback("INV-SAME"), account: account_a)

    expect(response).to have_http_status(:ok)
    expect(order_a.reload.status).to eq(OrderStatus::PAID)
    in_shop_b do
      expect(order_b.reload.status).to eq(OrderStatus::INVOICE_CREATED)
      expect(Payment.where(order_id: order_b.id)).to be_empty
      expect(CallbackLog.count).to eq(0)
    end
  end

  it "a callback to shop A's account for an invoice only shop B has is acknowledged and ignored" do
    order_b = in_shop_b { make_order(invoice: "INV-B-ONLY") }

    post_callback(paid_callback("INV-B-ONLY"), account: account_a)

    expect(response).to have_http_status(:ok)
    expect(CallbackLog.sole).to have_attributes(payment_account_id: account_a.id, process_error: "Order not found")
    in_shop_b { expect(order_b.reload.status).to eq(OrderStatus::INVOICE_CREATED) }
  end

  it "rejects a callback signed with shop B's password on shop A's endpoint" do
    order_a = make_order(invoice: "INV-A")

    post_callback(paid_callback("INV-A", secret: shop_b_secret), account: account_a)

    expect(response).to have_http_status(:unauthorized)
    expect(order_a.reload.status).to eq(OrderStatus::INVOICE_CREATED)
  end

  it "accepts shop B's own callback on shop B's endpoint and notifies shop B's staff only" do
    order_a = make_order(invoice: "INV-SAME")
    order_b = in_shop_b { make_order(invoice: "INV-SAME") }

    expect { post_callback(paid_callback("INV-SAME", secret: shop_b_secret), account: account_b) }
      .to have_enqueued_job(Payments::NotifyResultJob).with(shop_b.id, order_b.id, hash_including(notify_barista: true), true)
    perform_notifications

    in_shop_b { expect(order_b.reload.status).to eq(OrderStatus::PAID) }
    expect(order_a.reload.status).to eq(OrderStatus::INVOICE_CREATED)
    expect(api.messages_to(4004)).to be_present
    expect(api.messages_to(barista_id)).to be_empty
  end

  it "deduplicates per shop: the same body handled by shop B is still processed for shop A" do
    account_b.update!(password: TenancyHelpers::MWALLET_SECRET) # same password, byte-identical body
    order_a = make_order(invoice: "INV-SAME")
    order_b = in_shop_b { make_order(invoice: "INV-SAME") }
    body = paid_callback("INV-SAME")

    post_callback(body, account: account_b)
    post_callback(body, account: account_a)

    expect(order_a.reload.status).to eq(OrderStatus::PAID)
    in_shop_b { expect(order_b.reload.status).to eq(OrderStatus::PAID) }
  end

  it "a job for shop A never loads shop B's order" do
    order_b = in_shop_b { make_order(invoice: "INV-B") }
    expect_any_instance_of(MWallet::Client).not_to receive(:get_status)

    Payments::PollStatusJob.perform_now(shop_a.id, order_b.id)
    Payments::ExpireInvoiceJob.perform_now(shop_a.id, order_b.id)
    Payments::LatePaymentCheckJob.perform_now(shop_a.id, order_b.id)

    in_shop_b { expect(order_b.reload.status).to eq(OrderStatus::INVOICE_CREATED) }
  end

  it "the service refuses another shop's order" do
    order_b = in_shop_b { make_order(invoice: "INV-B") }

    expect { MWallet::Service.new(account_a).sync_status(order_b) }.to raise_error(ArgumentError)
    expect { MWallet::Service.new(account_a).cancel_invoice_for_order(order_b) }.to raise_error(ArgumentError)
  end
end
