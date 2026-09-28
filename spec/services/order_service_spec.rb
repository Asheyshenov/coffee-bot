# frozen_string_literal: true

require "rails_helper"

RSpec.describe OrderService do
  include_context "shop bot"

  describe ".cancel_by_client" do
    subject(:cancel) { described_class.cancel_by_client(order) }

    context "with a paid order" do
      let(:order) { make_order(status: OrderStatus::PAID) }

      it "keeps it and does not talk to the provider" do
        expect_any_instance_of(MWallet::Client).not_to receive(:get_status)
        expect_any_instance_of(MWallet::Client).not_to receive(:cancel_invoice)

        expect(cancel).to eq(:already_paid)
        expect(order.reload.status).to eq(OrderStatus::PAID)
      end
    end

    context "with an order in preparation" do
      let(:order) { make_order(status: OrderStatus::IN_PROGRESS) }

      it { expect(cancel).to eq(:in_progress) }
    end

    context "with a finished order" do
      let(:order) { make_order(status: OrderStatus::READY) }

      it "is not cancellable" do
        expect(cancel).to eq(:not_cancellable)
        expect(order.reload.status).to eq(OrderStatus::READY)
      end
    end

    context "with a NEW order without invoice" do
      let(:order) { make_order(status: OrderStatus::NEW, invoice: nil) }

      it "cancels it locally" do
        expect(cancel).to eq(:cancelled)
        expect(order.reload.status).to eq(OrderStatus::CANCELLED)
      end
    end

    context "with an INVOICE_CREATED order" do
      let(:order) { make_order }

      it "returns :paid_now when the last-chance sync finds the payment" do
        provider_reports("approved")

        expect(cancel).to eq(:paid_now)
        expect(order.reload.status).to eq(OrderStatus::PAID)
      end

      it "yields the winning sync result so the caller can send the payment notifications" do
        provider_reports("approved")

        expect { |b| described_class.cancel_by_client(order, &b) }
          .to yield_with_args(hash_including(updated: true, notify_barista: true))
      end

      it "returns :payment_problem and yields :payment_error when the sync finds an underpayment" do
        provider_reports("approved", amount: 10_000)
        expect_any_instance_of(MWallet::Client).not_to receive(:cancel_invoice)

        yielded = nil
        outcome = described_class.cancel_by_client(order) { |result| yielded = result }

        expect(outcome).to eq(:payment_problem)
        expect(order.reload.status).to eq(OrderStatus::ERROR)
        expect(yielded).to include(payment_error: :amount_mismatch, expected_amount: 15_000)
      end

      it "does not yield when nothing was settled by the sync" do
        provider_reports("pending")
        allow_any_instance_of(MWallet::Client).to receive(:cancel_invoice).and_return(cancel_confirmed)

        expect { |b| described_class.cancel_by_client(order, &b) }.not_to yield_control
      end

      it "does not yield when somebody else settled the order just before the sync" do
        allow(described_class).to receive(:sync_payment_status) do |o|
          o.update_column(:status, OrderStatus::PAID)
          { updated: false, order_id: o.id, notify_barista: false }
        end

        expect { |b| described_class.cancel_by_client(order, &b) }.not_to yield_control
        expect(order.reload.status).to eq(OrderStatus::PAID)
      end

      it "returns :already_paid when the order is paid while the provider cancel is in flight" do
        provider_reports("pending")
        allow_any_instance_of(MWallet::Client).to receive(:cancel_invoice) do
          order.update_column(:status, OrderStatus::PAID)
          cancel_confirmed
        end

        expect(cancel).to eq(:already_paid)
        expect(order.reload.status).to eq(OrderStatus::PAID)
      end

      it "returns :cancelled without calling the cancel API when the provider already cancelled it" do
        provider_reports("cancelled")
        expect_any_instance_of(MWallet::Client).not_to receive(:cancel_invoice)

        expect(cancel).to eq(:cancelled)
        expect(order.reload.status).to eq(OrderStatus::CANCELLED)
      end

      it "returns :cancelled when the provider confirms the cancel" do
        provider_reports("pending")
        allow_any_instance_of(MWallet::Client).to receive(:cancel_invoice).and_return(cancel_confirmed)

        expect(cancel).to eq(:cancelled)
        expect(order.reload.status).to eq(OrderStatus::CANCELLED)
      end

      it "returns :cancelled_locally when the cancel call fails unexpectedly" do
        provider_reports("pending")
        # The Faraday stub raises a plain RuntimeError, which the MWallet client does not wrap

        expect(cancel).to eq(:cancelled_locally)
        expect(order.reload.status).to eq(OrderStatus::CANCELLED)
      end
    end
  end

  describe ".sync_payment_status" do
    it "returns the MWallet sync result unchanged (extra keys like :late_payment included)" do
      order = make_order(status: OrderStatus::EXPIRED)
      result = { updated: true, order_id: order.id, notify_barista: false, late_payment: true }
      allow_any_instance_of(MWallet::Service).to receive(:sync_status).with(order).and_return(result)

      expect(described_class.sync_payment_status(order)).to eq(result)
    end

    it "does not ask the provider about an order without invoice" do
      order = make_order(status: OrderStatus::NEW, invoice: nil)
      expect_any_instance_of(MWallet::Service).not_to receive(:sync_status)

      expect(described_class.sync_payment_status(order)).to include(updated: false, notify_barista: false)
    end
  end

  describe ".create_invoice" do
    it "issues the invoice from the coffee shop's payment account" do
      stub_invoice_creation(invoice_id: "INV-77")
      order = make_order(status: OrderStatus::NEW, invoice: nil)
      order.update!(payment_account: nil)

      data = described_class.create_invoice(order)

      expect(data[:invoice_id]).to eq("INV-77")
      expect(order.reload).to have_attributes(payment_account: current_tenant.payment_account, invoice_id_provider: "INV-77",
                                              status: OrderStatus::INVOICE_CREATED)
    end

    it "raises when the coffee shop has no payment account" do
      order = make_order(status: OrderStatus::NEW, invoice: nil)
      order.update!(payment_account: nil)
      current_tenant.payment_account.update!(active: false)

      expect { described_class.create_invoice(order) }.to raise_error(OrderService::NoPaymentAccount)
    end
  end

  describe "barista queue" do
    it "claims atomically and only lets the claiming barista complete" do
      order = make_order(status: OrderStatus::PAID)

      expect(described_class.barista_queue).to eq([ order ])
      expect(described_class.claim_order(order.id, barista_id)).to be(true)
      expect(described_class.claim_order(order.id, 2003)).to be(false)
      expect(described_class.barista_in_progress(barista_id)).to eq([ order ])
      expect(described_class.complete_order(order.id, 2003)).to be(false)
      expect(described_class.complete_order(order.id, barista_id)).to be(true)
      expect(order.reload.status).to eq(OrderStatus::READY)
    end

    it "returns false for unknown orders" do
      expect(described_class.claim_order(0, barista_id)).to be(false)
      expect(described_class.complete_order(0, barista_id)).to be(false)
    end
  end

  describe "client orders" do
    it "lists the client's orders newest first and the active ones oldest first" do
      old = make_order(status: OrderStatus::PAID)
      recent = make_order(status: OrderStatus::INVOICE_CREATED, invoice: "INV-2")
      done = make_order(status: OrderStatus::READY, invoice: "INV-3")
      make_order(status: OrderStatus::PAID, user_id: 5555, invoice: "INV-4")

      expect(described_class.client_orders(client_id, limit: 2)).to eq([ done, recent ])
      expect(described_class.active_orders_for_client(client_id)).to eq([ old, recent ])
      expect(described_class.active_order_for_client(client_id)).to eq(old)
    end
  end
end
