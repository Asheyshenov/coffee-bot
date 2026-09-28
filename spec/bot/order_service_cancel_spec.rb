# frozen_string_literal: true

require_relative '../spec_helper'
require_relative 'support/router_spec_support'

RSpec.describe 'CoffeeBot::Services::OrderService.cancel_by_client' do
  include RouterSpecSupport

  subject(:cancel) { CoffeeBot::Services::OrderService.cancel_by_client(order) }

  context 'with a paid order' do
    let(:order) { make_order(status: OrderStatus::PAID) }

    it 'keeps it and does not talk to the provider' do
      expect_any_instance_of(MWallet::Client).not_to receive(:get_status)
      expect_any_instance_of(MWallet::Client).not_to receive(:cancel_invoice)

      expect(cancel).to eq(:already_paid)
      expect(order.refresh.status).to eq(OrderStatus::PAID)
    end
  end

  context 'with an order in preparation' do
    let(:order) { make_order(status: OrderStatus::IN_PROGRESS) }

    it { expect(cancel).to eq(:in_progress) }
  end

  context 'with a finished order' do
    let(:order) { make_order(status: OrderStatus::READY) }

    it 'is not cancellable' do
      expect(cancel).to eq(:not_cancellable)
      expect(order.refresh.status).to eq(OrderStatus::READY)
    end
  end

  context 'with a NEW order without invoice' do
    let(:order) { make_order(status: OrderStatus::NEW, invoice: nil) }

    it 'cancels it locally' do
      expect(cancel).to eq(:cancelled)
      expect(order.refresh.status).to eq(OrderStatus::CANCELLED)
    end
  end

  context 'with an INVOICE_CREATED order' do
    let(:order) { make_order }

    it 'returns :paid_now when the last-chance sync finds the payment' do
      provider_reports('approved')

      expect(cancel).to eq(:paid_now)
      expect(order.refresh.status).to eq(OrderStatus::PAID)
    end

    it 'yields the winning sync result so the caller can send the payment notifications' do
      provider_reports('approved')

      expect { |b| CoffeeBot::Services::OrderService.cancel_by_client(order, &b) }
        .to yield_with_args(hash_including(updated: true, notify_barista: true))
    end

    it 'returns :payment_problem and yields :payment_error when the sync finds an underpayment' do
      provider_reports('approved', amount: 10_000)
      expect_any_instance_of(MWallet::Client).not_to receive(:cancel_invoice)

      yielded = nil
      outcome = CoffeeBot::Services::OrderService.cancel_by_client(order) { |result| yielded = result }

      expect(outcome).to eq(:payment_problem)
      expect(order.refresh.status).to eq(OrderStatus::ERROR)
      expect(yielded).to include(payment_error: :amount_mismatch, expected_amount: 15_000)
    end

    it 'does not yield when nothing was settled by the sync' do
      provider_reports('pending')
      allow_any_instance_of(MWallet::Client).to receive(:cancel_invoice).and_return({})

      expect { |b| CoffeeBot::Services::OrderService.cancel_by_client(order, &b) }.not_to yield_control
    end

    it 'does not yield when somebody else settled the order just before the sync' do
      allow(CoffeeBot::Services::OrderService).to receive(:sync_payment_status) do |o|
        o.this.update(status: OrderStatus::PAID)
        { updated: false, order_id: o.id, notify_barista: false }
      end

      expect { |b| CoffeeBot::Services::OrderService.cancel_by_client(order, &b) }.not_to yield_control
      expect(order.refresh.status).to eq(OrderStatus::PAID)
    end

    it 'returns :already_paid when the order is paid while the provider cancel is in flight' do
      provider_reports('pending')
      allow_any_instance_of(MWallet::Client).to receive(:cancel_invoice) do
        order.this.update(status: OrderStatus::PAID)
        {}
      end

      expect(cancel).to eq(:already_paid)
      expect(order.refresh.status).to eq(OrderStatus::PAID)
    end

    it 'returns :cancelled without calling the cancel API when the provider already cancelled it' do
      provider_reports('cancelled')
      expect_any_instance_of(MWallet::Client).not_to receive(:cancel_invoice)

      expect(cancel).to eq(:cancelled)
      expect(order.refresh.status).to eq(OrderStatus::CANCELLED)
    end

    it 'returns :cancelled when the provider confirms the cancel' do
      provider_reports('pending')
      allow_any_instance_of(MWallet::Client).to receive(:cancel_invoice).and_return({})

      expect(cancel).to eq(:cancelled)
      expect(order.refresh.status).to eq(OrderStatus::CANCELLED)
    end

    it 'returns :cancelled_locally when the cancel call fails unexpectedly' do
      provider_reports('pending')
      # Faraday stub raises a plain RuntimeError, which the MWallet client does not wrap

      expect(cancel).to eq(:cancelled_locally)
      expect(order.refresh.status).to eq(OrderStatus::CANCELLED)
    end
  end
end

RSpec.describe 'CoffeeBot::Services::OrderService.expire_old_invoices' do
  include RouterSpecSupport

  it 'never overwrites an order that was paid after it was selected for expiry' do
    stale = make_order(invoice: 'INV-OLD')
    paid = make_order(invoice: 'INV-PAID')
    [stale, paid].each { |o| o.this.update(created_at: Time.now.utc - 3600) }
    # Simulate the race: `paid` is selected while still INVOICE_CREATED, then paid before the
    # UPDATE (datasets are frozen, so the hook is added via Sequel's with_extend)
    paid_id = paid.id
    race = Module.new do
      define_method(:select_map) do |*args|
        super(*args).tap { Order.where(id: paid_id).update(status: OrderStatus::PAID) }
      end
    end
    allow(Order).to receive(:for_update).and_wrap_original { |original, *args| original.call(*args).with_extend(race) }

    expect(CoffeeBot::Services::OrderService.expire_old_invoices(15)).to eq(1)
    expect(stale.refresh.status).to eq(OrderStatus::EXPIRED)
    expect(paid.refresh.status).to eq(OrderStatus::PAID)
  end
end

RSpec.describe 'CoffeeBot::Services::OrderService.sync_payment_status' do
  include RouterSpecSupport

  it 'returns the MWallet sync result unchanged (extra keys like :late_payment included)' do
    order = make_order(status: OrderStatus::EXPIRED)
    result = { updated: true, order_id: order.id, notify_barista: false, late_payment: true }
    allow_any_instance_of(MWallet::Service).to receive(:sync_status).with(order).and_return(result)

    expect(CoffeeBot::Services::OrderService.sync_payment_status(order)).to eq(result)
  end
end
