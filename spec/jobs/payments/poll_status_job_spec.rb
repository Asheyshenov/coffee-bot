# frozen_string_literal: true

require "rails_helper"

RSpec.describe Payments::PollStatusJob do
  def poll(order, invoice = order.invoice_id_provider, attempt = 0)
    described_class.perform_now(current_tenant.id, order.id, invoice, attempt)
  end

  describe ".schedule" do
    before { freeze_time }

    it "polls every few seconds, less often after the first two minutes" do
      order = make_order(invoice: "INV-P")

      described_class.schedule(order)
      described_class.schedule(order, attempt: described_class::FAST_POLLS)

      expect(described_class).to have_been_enqueued.with(current_tenant.id, order.id, "INV-P", 0).at(5.seconds.from_now)
      expect(described_class).to have_been_enqueued.with(current_tenant.id, order.id, "INV-P", described_class::FAST_POLLS)
                                                   .at(15.seconds.from_now)
    end

    it "stops at the payment deadline (the expiry job takes over)" do
      order = make_order
      order.update_columns(created_at: (current_tenant.order_expire_minutes.minutes - 3.seconds).ago)

      expect(described_class.schedule(order)).to be(false)
      expect(described_class).not_to have_been_enqueued
    end
  end

  it "keeps polling an unpaid invoice" do
    order = make_order(invoice: "INV-P")
    provider_returns("status" => "processing")

    poll(order, "INV-P", 3)

    expect(order.reload.status).to eq(OrderStatus::INVOICE_CREATED)
    expect(described_class).to have_been_enqueued.with(current_tenant.id, order.id, "INV-P", 4)
  end

  it "marks the order paid, enqueues the notifications and stops polling" do
    order = make_order
    provider_confirms

    poll(order)

    expect(order.reload.status).to eq(OrderStatus::PAID)
    expect(Payments::NotifyResultJob).to have_been_enqueued.with(current_tenant.id, order.id, hash_including(notify_barista: true), true)
    expect(described_class).not_to have_been_enqueued

    perform_notifications
    expect(texts_to(client_id).join).to include("Оплата прошла успешно")
    expect(texts_to(barista_id).join).to include("Новый заказ ##{order.id}")
  end

  it "does nothing once the order left INVOICE_CREATED (e.g. paid via callback)" do
    order = make_order
    order.mark_paid!(paid_amount: 15_000)
    expect_any_instance_of(MWallet::Client).not_to receive(:get_status)

    poll(order)

    expect(enqueued_jobs).to be_empty
  end

  it "stops a chain started for an invoice that was re-issued" do
    order = make_order(invoice: "INV-NEWER")
    expect_any_instance_of(MWallet::Client).not_to receive(:get_status)

    poll(order, "INV-OLDER")

    expect(enqueued_jobs).to be_empty
  end

  it "does not poll past the payment deadline" do
    order = make_overdue(make_order)
    expect_any_instance_of(MWallet::Client).not_to receive(:get_status)

    poll(order)

    expect(enqueued_jobs).to be_empty
  end

  it "keeps going when MWallet is unreachable" do
    order = make_order(invoice: "INV-P")
    allow_any_instance_of(MWallet::Client).to receive(:get_status).and_raise(MWalletError::ProviderTimeout, "timeout")

    expect { poll(order) }.not_to raise_error

    expect(order.reload.status).to eq(OrderStatus::INVOICE_CREATED)
    expect(described_class).to have_been_enqueued.with(current_tenant.id, order.id, "INV-P", 1)
  end

  it "uses a short timeout without retries" do
    order = make_order
    clients = []
    allow_any_instance_of(MWallet::Client).to receive(:get_status) do |client, _|
      clients << client
      { "data" => { "status" => "processing" } }
    end

    poll(order)

    expect(clients.sole).to have_attributes(timeout: 10, retry_count: 0)
  end

  it "tells the customer once when MWallet closed the invoice" do
    order = make_order
    provider_returns("status" => "canceled")

    poll(order)
    perform_notifications

    expect(order.reload).to have_attributes(status: OrderStatus::CANCELLED, last_notified_status: OrderStatus::CANCELLED)
    expect(texts_to(client_id).join).to include("Заказ ##{order.id} отменён", "Счёт аннулирован платёжной системой")
    expect(Payments::LatePaymentCheckJob).to have_been_enqueued
    expect(described_class).not_to have_been_enqueued
  end

  it "skips a missing tenant or order quietly" do
    expect { described_class.perform_now(0, 1) }.not_to raise_error
    expect { described_class.perform_now(current_tenant.id, 0) }.not_to raise_error
  end
end
