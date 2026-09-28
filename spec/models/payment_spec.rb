# frozen_string_literal: true

require "rails_helper"

RSpec.describe Payment do
  describe ".parse_amount" do
    it "parses Integer, numeric strings and comma decimals" do
      expect(described_class.parse_amount(15_000)).to eq(BigDecimal("15000"))
      expect(described_class.parse_amount(" 15000.50 ")).to eq(BigDecimal("15000.5"))
      expect(described_class.parse_amount("15 000,00")).to eq(BigDecimal("15000"))
      expect(described_class.parse_amount(150.5)).to eq(BigDecimal("150.5"))
    end

    it "returns nil for a missing amount and raises for garbage" do
      expect(described_class.parse_amount(nil)).to be_nil
      expect(described_class.parse_amount("")).to be_nil
      expect { described_class.parse_amount("abc") }.to raise_error(ArgumentError)
      expect { described_class.parse_amount("Infinity") }.to raise_error(ArgumentError)
      expect { described_class.parse_amount({}) }.to raise_error(ArgumentError)
    end
  end

  describe "refund limits" do
    let(:order) { make_order(status: OrderStatus::PAID, total: 10_000) }
    let(:payment) { described_class.create!(order: order, invoice_id_provider: "INV-123", paid_amount: 10_000, status: PaymentStatus::PAID) }

    def refund!(amount)
      PaymentOperation.create!(order: order, operation_type: PaymentOperationType::REFUND, amount: amount,
                               status: PaymentOperationStatus::COMPLETED)
    end

    it "prevents a refund exceeding the paid amount and allows a partial one" do
      expect(payment.can_refund?(15_000)).to be(false)
      expect(payment.can_refund?(5_000)).to be(true)
      expect(payment.can_refund?(0)).to be(false)
    end

    it "counts completed refunds only" do
      refund!(7_000)
      PaymentOperation.create!(order: order, operation_type: PaymentOperationType::REFUND, amount: 1_000,
                               status: PaymentOperationStatus::FAILED)

      expect(payment.remaining_refundable).to eq(3_000)
      expect(payment.can_refund?(5_000)).to be(false)
      expect(payment.can_refund?(3_000)).to be(true)
      expect(payment.fully_refunded?).to be(false)

      refund!(3_000)
      expect(payment.fully_refunded?).to be(true)
    end

    it "refunds only PAID payments" do
      payment.update!(status: PaymentStatus::REFUND_REQUIRED)

      expect(payment.refundable?).to be(false)
      expect(payment.can_refund?(1_000)).to be(false)
    end
  end

  it "treats money actually received as settled" do
    order = make_order
    expect(PaymentStatus::SETTLED).to contain_exactly(PaymentStatus::PAID, PaymentStatus::REFUNDED_PARTIAL,
                                                     PaymentStatus::REFUNDED_FULL, PaymentStatus::REFUND_REQUIRED)
    described_class.create!(order: order, status: PaymentStatus::FAILED)

    expect(described_class.settled).to be_empty
  end
end
