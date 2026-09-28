# frozen_string_literal: true

require "rails_helper"

RSpec.describe Payments::LatePaymentCheckJob do
  def check(order, step = 0) = described_class.perform_now(current_tenant.id, order.id, step)

  describe ".schedule" do
    before { freeze_time }

    it "checks at 1m, 5m, 15m, 1h, 6h and 24h after the order was closed" do
      order = make_order(status: OrderStatus::EXPIRED)
      provider_returns("status" => "canceled")
      start = Time.current
      check_times = []

      described_class.schedule(order)
      while (job = enqueued_jobs.find { |j| j["job_class"] == described_class.name })
        enqueued_jobs.delete(job)
        travel_to(Time.zone.at(job["scheduled_at"].is_a?(String) ? Time.zone.parse(job["scheduled_at"]) : job["scheduled_at"]))
        check_times << (Time.current - start).round
        check(order, job["arguments"].last)
      end

      expect(check_times).to eq([ 1.minute, 5.minutes, 15.minutes, 1.hour, 6.hours, 24.hours ].map(&:to_i))
    end

    it "does nothing after the last check" do
      expect(described_class.schedule(make_order(status: OrderStatus::EXPIRED), step: 6)).to be(false)
    end
  end

  describe ".candidate?" do
    it "is an EXPIRED / CANCELLED order with an invoice and no settled payment" do
      expect(described_class.candidate?(make_order(status: OrderStatus::EXPIRED, invoice: "A"))).to be(true)
      expect(described_class.candidate?(make_order(status: OrderStatus::CANCELLED, invoice: "B"))).to be(true)
      expect(described_class.candidate?(make_order(status: OrderStatus::EXPIRED, invoice: nil))).to be(false)
      expect(described_class.candidate?(make_order(status: OrderStatus::INVOICE_CREATED, invoice: "C"))).to be(false)
      expect(described_class.candidate?(make_order(status: OrderStatus::READY, invoice: "D"))).to be(false)
      refunded = make_order(status: OrderStatus::CANCELLED, invoice: "E")
      Payment.create!(order: refunded, paid_amount: 15_000, status: PaymentStatus::REFUNDED_FULL)
      expect(described_class.candidate?(refunded)).to be(false)
    end
  end

  it "schedules the next check while nothing was paid" do
    order = make_order(status: OrderStatus::EXPIRED)
    provider_returns("status" => "canceled")

    check(order, 2)

    expect(described_class).to have_been_enqueued.with(current_tenant.id, order.id, 3)
    expect(Payments::NotifyResultJob).not_to have_been_enqueued
  end

  it "records a late payment, notifies staff and the customer once and stops checking" do
    order = make_order(status: OrderStatus::EXPIRED, invoice: "INV-LATE-POLL")
    provider_confirms

    check(order)
    check(order, 1) # a stray duplicate run
    perform_notifications

    expect(order.reload.status).to eq(OrderStatus::EXPIRED)
    expect(order.payment.status).to eq(PaymentStatus::REFUND_REQUIRED)
    expect(texts_to(client_id).join.scan("деньги вернём").size).to eq(1)
    expect(texts_to(barista_id).join.scan("Требуется возврат по заказу ##{order.id}").size).to eq(1)
    expect(described_class).not_to have_been_enqueued
  end

  it "does not call MWallet for non-candidates" do
    expect_any_instance_of(MWallet::Client).not_to receive(:get_status)

    check(make_order(status: OrderStatus::PAID, invoice: "P"))
    check(make_order(status: OrderStatus::EXPIRED, invoice: nil))

    expect(enqueued_jobs).to be_empty
  end

  it "moves on to the next check when MWallet is unreachable or refuses" do
    order = make_order(status: OrderStatus::CANCELLED)
    allow_any_instance_of(MWallet::Client).to receive(:get_status).and_raise(MWalletError::ProviderTimeout, "timeout")

    expect { check(order) }.not_to raise_error
    expect(described_class).to have_been_enqueued.with(current_tenant.id, order.id, 1)

    allow_any_instance_of(MWallet::Client).to receive(:get_status).and_raise(MWalletError::BusinessError, "invoice cancelled")
    expect { check(order, 1) }.not_to raise_error
    expect(described_class).to have_been_enqueued.with(current_tenant.id, order.id, 2)
  end

  it "stops after the 24h check" do
    order = make_order(status: OrderStatus::EXPIRED)
    provider_returns("status" => "canceled")

    check(order, 5)

    expect(described_class).not_to have_been_enqueued
  end
end
