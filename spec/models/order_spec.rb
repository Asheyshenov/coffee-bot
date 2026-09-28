# frozen_string_literal: true

require "rails_helper"

# Status changes that can race are conditional UPDATEs: exactly one caller wins.
# Concurrency is simulated with stale instances loaded before the other worker acted.
RSpec.describe Order do
  describe "#mark_paid!" do
    it "has exactly one winner when two workers mark the same order paid" do
      order = make_order
      callback_copy = stale_copy(order)
      poller_copy = stale_copy(order)

      results = [ callback_copy.mark_paid!(paid_amount: 15_000), poller_copy.mark_paid!(paid_amount: 15_000) ]

      expect(results).to eq([ true, false ])
      expect(order.reload.status).to eq(OrderStatus::PAID)
      expect(Payment.where(order_id: order.id).pluck(:status)).to eq([ PaymentStatus::PAID ])
    end

    it "loses against an expiry that already moved the order to EXPIRED" do
      order = make_order
      stale = stale_copy(order)
      Order.where(id: order.id).update_all(status: OrderStatus::EXPIRED)

      expect(stale.mark_paid!(paid_amount: 15_000)).to be(false)
      expect(order.reload.status).to eq(OrderStatus::EXPIRED)
      expect(Payment.where(order_id: order.id)).to be_empty
    end

    it "records the payment inside the same transaction as the status change" do
      order = make_order
      allow(Payment).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "disk full")

      expect { order.mark_paid!(paid_amount: 15_000) }.to raise_error(ActiveRecord::StatementInvalid)
      expect(order.reload.status).to eq(OrderStatus::INVOICE_CREATED)
    end

    it "has one winner between a payment and a payment error on the same order" do
      order = make_order
      stale = stale_copy(order)

      expect(order.mark_paid!(paid_amount: 15_000)).to be(true)
      expect(stale.mark_payment_error!(reason: "AMOUNT_MISMATCH", paid_amount: 100)).to be(false)
      expect(order.reload.status).to eq(OrderStatus::PAID)
    end

    it "is not overwritten by an expiry holding a stale instance" do
      order = make_order
      stale_for_expiry = stale_copy(order)

      expect(order.mark_paid!(paid_amount: 15_000)).to be(true)
      expect(stale_for_expiry.expire!).to be(false)
      expect(order.reload.status).to eq(OrderStatus::PAID)
      expect(stale_for_expiry.status).to eq(OrderStatus::PAID)
    end

    it "accepts numeric strings as paid amount and defaults to the total" do
      order = make_order(invoice: "A")
      order.mark_paid!(paid_amount: "15000.00")
      expect(order.payment.paid_amount).to eq(15_000)

      other = make_order(invoice: "B", total: 12_000)
      other.mark_paid!
      expect(other.payment.paid_amount).to eq(12_000)
    end

    it "never pays an order that is not waiting for payment" do
      [ OrderStatus::NEW, OrderStatus::CANCELLED, OrderStatus::ERROR, OrderStatus::READY ].each_with_index do |status, i|
        expect(make_order(status: status, invoice: "S-#{i}").mark_paid!(paid_amount: 15_000)).to be(false)
      end
    end
  end

  describe "#record_late_payment!" do
    it "records a refund for an EXPIRED order once and keeps the order status" do
      order = make_order(status: OrderStatus::EXPIRED)
      stale = stale_copy(order)

      expect(order.record_late_payment!(paid_amount: "100")).to eq(OrderStatus::EXPIRED)
      expect(stale.record_late_payment!(paid_amount: 100)).to be_nil

      expect(order.reload.status).to eq(OrderStatus::EXPIRED)
      expect(order.invoice_status_raw).to eq(PaymentStatus::REFUND_REQUIRED)
      expect(order.payment).to have_attributes(status: PaymentStatus::REFUND_REQUIRED, paid_amount: 100)
      expect(order.refund_required?).to be(true)
    end

    it "is only for EXPIRED / CANCELLED orders without a settled payment" do
      expect(make_order(invoice: "A").record_late_payment!).to be_nil
      expect(make_order(status: OrderStatus::PAID, invoice: "B").record_late_payment!).to be_nil

      refunded = make_order(status: OrderStatus::CANCELLED, invoice: "C")
      Payment.create!(order: refunded, paid_amount: 15_000, status: PaymentStatus::REFUNDED_FULL)
      expect(refunded.record_late_payment!).to be_nil
      expect(refunded.reload.payment.status).to eq(PaymentStatus::REFUNDED_FULL)
    end
  end

  describe "#mark_refunded!" do
    it "closes a required refund once, with an audit operation" do
      order = make_order(status: OrderStatus::CANCELLED)
      order.record_late_payment!(paid_amount: 15_000)

      expect(order.mark_refunded!(barista_id)).to be(true)
      expect(stale_copy(order).mark_refunded!(barista_id)).to be(false)

      expect(order.reload.payment.status).to eq(PaymentStatus::REFUNDED_FULL)
      expect(order.invoice_status_raw).to eq(PaymentStatus::REFUNDED_FULL)
      expect(order.payment_operations.sole).to have_attributes(operation_type: PaymentOperationType::REFUND, amount: 15_000,
                                                               status: PaymentOperationStatus::COMPLETED)
      expect(order.payment_operations.sole.reason).to include(barista_id.to_s)
    end

    it "does nothing without a required refund" do
      expect(make_order(status: OrderStatus::PAID).mark_refunded!(barista_id)).to be(false)
    end
  end

  describe "#mark_payment_error!" do
    it "moves INVOICE_CREATED to ERROR once, with a FAILED payment and the reason" do
      order = make_order

      expect(order.mark_payment_error!(reason: "AMOUNT_MISMATCH: expected 15000, got 100", paid_amount: 100)).to be(true)
      expect(stale_copy(order).mark_payment_error!(reason: "again")).to be(false)

      expect(order.reload).to have_attributes(status: OrderStatus::ERROR, invoice_status_raw: "AMOUNT_MISMATCH: expected 15000, got 100")
      expect(order.payment).to have_attributes(status: PaymentStatus::FAILED, paid_amount: 100)
    end
  end

  describe "#expire! and #cancel_unpaid!" do
    it "expire! only closes an INVOICE_CREATED order" do
      expect(make_order(invoice: "A").expire!).to be(true)
      expect(make_order(status: OrderStatus::NEW, invoice: "B").expire!).to be(false)
      expect(make_order(status: OrderStatus::PAID, invoice: "C").expire!).to be(false)
    end

    it "cancel_unpaid! only cancels NEW / INVOICE_CREATED orders" do
      expect(make_order(status: OrderStatus::NEW, invoice: "A").cancel_unpaid!).to be(true)
      invoice_created = make_order(invoice: "B")
      expect(invoice_created.cancel_unpaid!).to be(true)
      expect(invoice_created.status).to eq(OrderStatus::CANCELLED)
      expect(make_order(status: OrderStatus::PAID, invoice: "C").cancel_unpaid!).to be(false)
    end
  end

  describe "#claim_for_barista!" do
    it "lets only one barista claim a paid order" do
      order = make_order(status: OrderStatus::PAID)
      copies = Array.new(5) { stale_copy(order) }

      results = copies.each_with_index.map { |copy, i| copy.claim_for_barista!(barista_id + i) }

      expect(results.count(true)).to eq(1)
      expect(order.reload).to have_attributes(status: OrderStatus::IN_PROGRESS, assigned_to_barista_id: barista_id)
    end
  end

  describe "#transition_to!" do
    it "validates transitions" do
      order = make_order(status: OrderStatus::NEW)

      expect { order.transition_to!(OrderStatus::PAID) }.to raise_error(Order::InvalidStatusTransition)
      expect(order.transition_to!(OrderStatus::INVOICE_CREATED)).to be(true)
    end
  end

  describe "#payment_deadline" do
    it "is created_at plus the shop's order_expire_minutes" do
      current_tenant.update!(order_expire_minutes: 30)
      order = make_order

      expect(order.payment_deadline).to eq(order.created_at + 30.minutes)
      expect(order.payment_deadline_passed?).to be(false)
      expect(make_overdue(order, minutes: 31).payment_deadline_passed?).to be(true)
    end
  end

  describe "#set_invoice_data" do
    it "stores the provider invoice" do
      order = make_order(status: OrderStatus::NEW, invoice: nil)

      order.set_invoice_data(invoice_id: "INV-9", paylink_url: "https://pay.test", emv_qr_url: "https://qr.test",
                             emv_qr_data: "0002", qr_image_base64: "b64", raw_response: "{}")

      expect(order.reload).to have_attributes(invoice_id_provider: "INV-9", qr_url: "https://pay.test",
                                              emv_qr_url: "https://qr.test", qr_payload: "0002", qr_image_base64: "b64")
    end
  end
end
