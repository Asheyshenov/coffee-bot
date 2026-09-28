# frozen_string_literal: true

require "rails_helper"

# Port of the legacy InvoiceExpirer spec: one job per order at its payment deadline
RSpec.describe Payments::ExpireInvoiceJob do
  def overdue_order(invoice: "INV-EXP-1", total: 15_000, age_minutes: 60)
    make_overdue(make_order(invoice: invoice, total: total), minutes: age_minutes)
  end

  def expire(order) = described_class.perform_now(current_tenant.id, order.id)

  def cancel_succeeds
    allow_any_instance_of(MWallet::Client).to receive(:cancel_invoice).and_return({ "data" => { "success" => true } })
  end

  def expired_texts = texts_to(client_id).grep(/Время оплаты истекло/)

  before { provider_returns("status" => "processing") }

  describe ".schedule" do
    it "runs at the order's payment deadline (the shop's order_expire_minutes)" do
      current_tenant.update!(order_expire_minutes: 25)
      order = make_order

      described_class.schedule(order)

      expect(described_class).to have_been_enqueued.with(current_tenant.id, order.id).at(order.created_at + 25.minutes)
    end
  end

  it "cancels the invoice at the provider, marks the order EXPIRED, notifies the client and schedules late checks" do
    order = overdue_order
    expect_any_instance_of(MWallet::Client).to receive(:cancel_invoice).with("INV-EXP-1").and_return({ "data" => { "success" => true } })

    expire(order)

    order.reload
    expect(order.status).to eq(OrderStatus::EXPIRED)
    expect(order.last_notified_status).to eq(OrderStatus::EXPIRED)
    expect(expired_texts.size).to eq(1)
    expect(Payments::LatePaymentCheckJob).to have_been_enqueued.with(current_tenant.id, order.id, 0)
  end

  it "comes back later when it fires before the deadline" do
    freeze_time
    order = make_order
    expect_any_instance_of(MWallet::Client).not_to receive(:cancel_invoice)

    expire(order)

    expect(order.reload.status).to eq(OrderStatus::INVOICE_CREATED)
    expect(described_class).to have_been_enqueued.with(current_tenant.id, order.id).at(order.payment_deadline)
    expect(api.calls).to be_empty
  end

  it "expires anyway when the last-chance payment check cannot reach the provider" do
    order = overdue_order
    allow_any_instance_of(MWallet::Client).to receive(:get_status).and_call_original # network kill switch
    cancel_succeeds

    expire(order)

    expect(order.reload.status).to eq(OrderStatus::EXPIRED)
    expect(expired_texts.size).to eq(1)
  end

  it "is idempotent: a second run changes and sends nothing" do
    order = overdue_order
    cancel_succeeds

    2.times { expire(order) }

    expect(expired_texts.size).to eq(1)
    expect(Payments::LatePaymentCheckJob).to have_been_enqueued.exactly(:once)
  end

  context "when the order turns out to be paid at the last moment" do
    before { provider_confirms }

    it "skips expiry and notifies the client and the baristas about the payment" do
      order = overdue_order
      expect_any_instance_of(MWallet::Client).not_to receive(:cancel_invoice)

      expire(order)
      perform_notifications

      expect(order.reload.status).to eq(OrderStatus::PAID)
      expect(texts_to(client_id).join).to include("Оплата прошла успешно")
      expect(texts_to(barista_id).join).to include("Новый заказ ##{order.id}")
      expect(expired_texts).to be_empty
    end
  end

  context "when the last-chance check finds a payment problem" do
    before { provider_confirms(amount: 100) }

    it "passes the result to the notifications and does not expire or cancel the invoice" do
      order = overdue_order
      expect_any_instance_of(MWallet::Client).not_to receive(:cancel_invoice)

      expire(order)

      expect(order.reload.status).to eq(OrderStatus::ERROR)
      expect(Payments::NotifyResultJob).to have_been_enqueued
        .with(current_tenant.id, order.id, hash_including(payment_error: "amount_mismatch"), true)
      perform_notifications
      expect(texts_to(barista_id).join).to include("Проблема с оплатой заказа ##{order.id}")
      expect(expired_texts).to be_empty
    end
  end

  context "when the provider already closed the invoice during the payment check" do
    before { provider_returns("status" => "canceled") }

    it "does not expire or cancel again, but tells the client once" do
      order = overdue_order
      expect_any_instance_of(MWallet::Client).not_to receive(:cancel_invoice)

      2.times { expire(order) }

      order.reload
      expect(order.status).to eq(OrderStatus::CANCELLED)
      expect(order.last_notified_status).to eq(OrderStatus::CANCELLED)
      expect(expired_texts.size).to eq(1)
      expect(Payments::LatePaymentCheckJob).to have_been_enqueued.exactly(:once)
    end
  end

  context "when cancelling the invoice at the provider fails" do
    it "still expires the order and notifies the client" do
      order = overdue_order
      allow_any_instance_of(MWallet::Client).to receive(:cancel_invoice)
        .and_raise(MWalletError::NetworkError.new("Network error: connection refused"))

      expire(order)

      order.reload
      expect(order.status).to eq(OrderStatus::EXPIRED)
      expect(order.last_notified_status).to eq(OrderStatus::EXPIRED)
      expect(Payments::LatePaymentCheckJob).to have_been_enqueued
    end

    it "handles unexpected (non-MWallet) errors the same way" do
      order = overdue_order # cancel_invoice hits the network kill switch (RuntimeError)

      expire(order)

      expect(order.reload.status).to eq(OrderStatus::EXPIRED)
    end
  end

  context "when expire! loses a race" do
    it "does not notify when a callback marked the order PAID during the provider call" do
      order = overdue_order
      allow_any_instance_of(MWallet::Client).to receive(:cancel_invoice) do
        Order.where(id: order.id).update_all(status: OrderStatus::PAID) # concurrent callback
        {}
      end

      expire(order)

      order.reload
      expect(order.status).to eq(OrderStatus::PAID)
      expect(order.last_notified_status).to be_nil
      expect(api.calls).to be_empty
      expect(Payments::LatePaymentCheckJob).not_to have_been_enqueued
    end

    it "never overwrites a payment committed after the last re-read (conditional UPDATE in expire!)" do
      order = overdue_order
      cancel_succeeds
      allow_any_instance_of(Order).to receive(:expire!).and_wrap_original do |original, *args|
        # The job has already re-read the order: in memory it is still INVOICE_CREATED
        expect(original.receiver.status).to eq(OrderStatus::INVOICE_CREATED)
        # ...and right now the callback commits the payment
        expect(stale_copy(order).mark_paid!(paid_amount: 15_000)).to be(true)
        original.call(*args)
      end

      expire(order)

      order.reload
      expect(order.status).to eq(OrderStatus::PAID)
      expect(order.payment.status).to eq(PaymentStatus::PAID)
      expect(order.last_notified_status).to be_nil
      expect(expired_texts).to be_empty
    end
  end

  context "when notifying the client fails" do
    it "keeps the order EXPIRED, leaves it unmarked as notified and still schedules late checks" do
      order = overdue_order
      cancel_succeeds
      allow_any_instance_of(Notifier).to receive(:notify_invoice_expired).and_raise(StandardError, "telegram down")

      expect { expire(order) }.not_to raise_error

      order.reload
      expect(order.status).to eq(OrderStatus::EXPIRED)
      expect(order.last_notified_status).to be_nil
      expect(Payments::LatePaymentCheckJob).to have_been_enqueued
    end
  end

  it "uses the credentials of the order's own payment account" do
    order = overdue_order
    order.payment_account.update!(active: false, sid: "OLD")
    PaymentAccount.create!(tenant: current_tenant, sid: "NEW", password: "p", base_url: PaymentAccount::TEST_BASE_URL)
    sids = []
    allow_any_instance_of(MWallet::Client).to receive(:cancel_invoice) { |client, _| sids << client.sid }

    expire(order)

    expect(sids).to eq([ "OLD" ])
  end
end
