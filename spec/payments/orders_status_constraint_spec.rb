# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Payment status database constraints (Postgres CHECK)" do
  # A failed statement aborts the Postgres transaction: run it in a savepoint
  def in_savepoint(&block) = ActiveRecord::Base.transaction(requires_new: true, &block)

  it "rejects order statuses outside OrderStatus::ALL on update and insert" do
    order = make_order

    expect { in_savepoint { order.update_column(:status, "cancelled") } }
      .to raise_error(ActiveRecord::StatementInvalid, /orders_status_check/)
    expect do
      in_savepoint do
        Order.insert_all!([ { tenant_id: current_tenant.id, customer_id: order.customer_id, telegram_user_id: 1,
                              client_display_name: "T", status: "bogus", total_amount: 100, merchant_invoice_id: "M-BOGUS" } ])
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /orders_status_check/)
    expect(order.reload.status).to eq(OrderStatus::INVOICE_CREATED)
  end

  it "accepts every OrderStatus::ALL value" do
    order = make_order

    OrderStatus::ALL.each do |status|
      expect { in_savepoint { order.update_column(:status, status) } }.not_to raise_error
    end
  end

  it "rejects payment statuses outside PaymentStatus::ALL and accepts all of them" do
    payment = Payment.create!(order: make_order, status: PaymentStatus::PENDING)

    expect { in_savepoint { payment.update_column(:status, "paid") } }
      .to raise_error(ActiveRecord::StatementInvalid, /payments_status_check/)
    PaymentStatus::ALL.each do |status|
      expect { in_savepoint { payment.update_column(:status, status) } }.not_to raise_error
    end
  end

  it "allows one payment record per order" do
    order = make_order
    Payment.create!(order: order, status: PaymentStatus::PAID)

    expect { in_savepoint { Payment.create!(order: order, status: PaymentStatus::PAID) } }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "keeps invoice ids unique per payment account" do
    make_order(invoice: "INV-UNIQUE")

    expect { in_savepoint { make_order(invoice: "INV-UNIQUE") } }.to raise_error(ActiveRecord::RecordNotUnique)
  end
end
