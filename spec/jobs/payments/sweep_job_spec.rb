# frozen_string_literal: true

require "rails_helper"

RSpec.describe Payments::SweepJob do
  let(:grace) { described_class::GRACE_PERIOD }

  before do
    provider_returns("status" => "processing")
    allow_any_instance_of(MWallet::Client).to receive(:cancel_invoice).and_return({ "data" => { "success" => true } })
  end

  def lost_order(invoice:, minutes_overdue: 5)
    order = make_order(invoice: invoice)
    order.update_columns(created_at: (current_tenant.order_expire_minutes.minutes + minutes_overdue.minutes).ago)
    order
  end

  it "expires overdue unpaid orders of every serving coffee shop and tells the customers" do
    order_a = lost_order(invoice: "INV-A")
    shop_b = other_tenant(barista_ids: [])
    order_b = ActsAsTenant.with_tenant(shop_b) { lost_order(invoice: "INV-B") }

    ActsAsTenant.current_tenant = nil
    described_class.perform_now
    ActsAsTenant.current_tenant = Tenant.find(order_a.tenant_id)

    expect(order_a.reload.status).to eq(OrderStatus::EXPIRED)
    ActsAsTenant.with_tenant(shop_b) { expect(order_b.reload.status).to eq(OrderStatus::EXPIRED) }
    expect(api.messages_to(client_id).map { |m| m[:text] }.grep(/Время оплаты истекло/).size).to eq(2)
  end

  it "leaves orders alone while their expiry job still has time, and other statuses" do
    fresh = make_order(invoice: "INV-FRESH")
    within_grace = make_order(invoice: "INV-GRACE")
    within_grace.update_columns(created_at: (current_tenant.order_expire_minutes.minutes + grace - 30.seconds).ago)
    paid = lost_order(invoice: "INV-PAID")
    paid.update_columns(status: OrderStatus::PAID)
    expect_any_instance_of(MWallet::Client).not_to receive(:cancel_invoice)

    described_class.perform_now

    expect([ fresh, within_grace ].map { |o| o.reload.status }).to all(eq(OrderStatus::INVOICE_CREATED))
    expect(paid.reload.status).to eq(OrderStatus::PAID)
  end

  it "skips suspended coffee shops" do
    current_tenant.update!(status: "suspended")
    order = lost_order(invoice: "INV-SUSP")

    described_class.perform_now

    expect(order.reload.status).to eq(OrderStatus::INVOICE_CREATED)
  end

  it "handles at most BATCH_SIZE orders per shop and run, oldest first" do
    stub_const("#{described_class}::BATCH_SIZE", 1)
    older = lost_order(invoice: "INV-OLD", minutes_overdue: 30)
    newer = lost_order(invoice: "INV-NEW", minutes_overdue: 10)

    described_class.perform_now
    expect([ older.reload.status, newer.reload.status ]).to eq([ OrderStatus::EXPIRED, OrderStatus::INVOICE_CREATED ])

    described_class.perform_now
    expect(newer.reload.status).to eq(OrderStatus::EXPIRED)
  end

  it "does not let one broken order block the rest" do
    broken = lost_order(invoice: "INV-BROKEN", minutes_overdue: 30)
    fine = lost_order(invoice: "INV-FINE", minutes_overdue: 10)
    allow(Payments::ExpireInvoiceJob).to receive(:perform_now).and_call_original
    allow(Payments::ExpireInvoiceJob).to receive(:perform_now).with(current_tenant.id, broken.id).and_raise(StandardError, "boom")

    expect { described_class.perform_now }.not_to raise_error

    expect(broken.reload.status).to eq(OrderStatus::INVOICE_CREATED)
    expect(fine.reload.status).to eq(OrderStatus::EXPIRED)
  end

  it "never runs twice at the same time (Solid Queue concurrency control)" do
    expect(described_class.concurrency_limit).to eq(1)
    expect(described_class.concurrency_on_conflict).to eq(:discard)
  end
end
