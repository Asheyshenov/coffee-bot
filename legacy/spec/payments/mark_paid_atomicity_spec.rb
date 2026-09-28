# frozen_string_literal: true

require_relative 'payments_helper'

# Concurrency is simulated with stale model instances: every "worker" loaded the
# order while it was INVOICE_CREATED (the in-memory SQLite test DB has a single
# connection, so real threads can't overlap inside a transaction).
RSpec.describe 'Payments: atomic status transitions' do
  include_context 'payments sandbox'

  describe 'Order#mark_paid!' do
    it 'has exactly one winner when two workers mark the same order paid' do
      order = make_order
      callback_copy = Order[order.id]
      syncer_copy = Order[order.id]

      results = [callback_copy.mark_paid!(paid_amount: 15_000), syncer_copy.mark_paid!(paid_amount: 15_000)]

      expect(results).to eq([true, false])
      expect(order.refresh.status).to eq(OrderStatus::PAID)
      expect(Payment.where(order_id: order.id).count).to eq(1)
      expect(Payment.where(order_id: order.id).first.status).to eq(PaymentStatus::PAID)
    end

    it 'loses against an expirer that already moved the order to EXPIRED (without allow_late)' do
      order = make_order
      stale = Order[order.id]
      Order.where(id: order.id).update(status: OrderStatus::EXPIRED)

      expect(stale.mark_paid!(paid_amount: 15_000)).to be(false)
      expect(order.refresh.status).to eq(OrderStatus::EXPIRED)
      expect(Payment.where(order_id: order.id).count).to eq(0)
    end

    it 'records the payment inside the same transaction as the status change' do
      order = make_order
      allow(Payment).to receive(:new).and_raise(Sequel::DatabaseError, 'disk full')

      expect { order.mark_paid!(paid_amount: 15_000) }.to raise_error(Sequel::DatabaseError)
      expect(order.refresh.status).to eq(OrderStatus::INVOICE_CREATED)
    end

    it 'has one winner between a payment and a payment error on the same order' do
      order = make_order
      stale = Order[order.id]

      expect(order.mark_paid!(paid_amount: 15_000)).to be(true)
      expect(stale.mark_payment_error!(reason: 'AMOUNT_MISMATCH', paid_amount: 100)).to be(false)
      expect(order.refresh.status).to eq(OrderStatus::PAID)
    end

    it 'is not overwritten by an expirer holding a stale instance (Order#expire!)' do
      order = make_order
      stale_for_expirer = Order[order.id]

      expect(order.mark_paid!(paid_amount: 15_000)).to be(true)
      expect(stale_for_expirer.expire!).to be(false)
      expect(order.refresh.status).to eq(OrderStatus::PAID)
      expect(stale_for_expirer.status).to eq(OrderStatus::PAID)
    end

    it 'accepts numeric strings as paid amount' do
      order = make_order
      order.mark_paid!(paid_amount: '15000.00')
      expect(Payment.where(order_id: order.id).first.paid_amount).to eq(15_000)
    end
  end

  describe 'MWallet::Service (callback vs polling race)' do
    include Rack::Test::Methods
    def app = CoffeeBot::HTTP::CallbackApp

    before { CoffeeBot::HTTP::CallbackApp.set :host_authorization, { permitted_hosts: [] } }

    it 'notifies only once when callback and StatusSyncer both see the payment' do
      order = make_order(invoice: 'INV-RACE')
      stale_for_syncer = Order[order.id]
      stub_provider_status(status: 'approved', amount: 15_000)

      post '/callbacks/mwallet/result',
           signed_body({ 'invoice_id' => 'INV-RACE', 'status' => 3, 'amount' => 15_000 }),
           'CONTENT_TYPE' => 'application/json'
      result = MWallet::Service.new.sync_status(stale_for_syncer)

      expect(result).to include(updated: false, notify_barista: false)
      expect(api.messages_to(PaymentsSpec::CLIENT_ID).grep(/Оплата прошла успешно/).size).to eq(1)
      expect(api.messages_to(PaymentsSpec::BARISTA_ID).grep(/Новый заказ ##{order.id}/).size).to eq(1)
    end

    it 'a stale "rejected" poll does not cancel an order paid meanwhile via callback' do
      order = make_order(invoice: 'INV-STALE')
      stale_for_syncer = Order[order.id]
      # The syncer's statusPayment snapshot still shows only the declined first attempt
      stub_provider_status(status: 'rejected', amount: 15_000)

      post '/callbacks/mwallet/result',
           signed_body({ 'invoice_id' => 'INV-STALE', 'status' => 3, 'amount' => 15_000 }),
           'CONTENT_TYPE' => 'application/json'
      result = MWallet::Service.new.sync_status(stale_for_syncer)

      expect(result).to include(updated: false, notify_barista: false)
      expect(order.refresh.status).to eq(OrderStatus::PAID)
      expect(Payment.where(order_id: order.id).select_map(:status)).to eq([PaymentStatus::PAID])
    end

    it 'a provider "cancelled" status never moves a PAID order' do
      order = make_order
      order.mark_paid!(paid_amount: 15_000)
      stub_provider_status(status: 'cancelled')

      expect(MWallet::Service.new.sync_status(order)).to include(updated: false)
      expect(order.refresh.status).to eq(OrderStatus::PAID)
    end

    it 'a provider "cancelled" status still closes an unpaid invoice' do
      order = make_order
      stub_provider_status(status: 'cancelled')

      expect(MWallet::Service.new.sync_status(order)).to include(updated: true, notify_barista: false)
      expect(order.refresh.status).to eq(OrderStatus::CANCELLED)
    end

    it 'cancel_invoice_for_order does not overwrite an order paid in the meantime' do
      order = make_order
      stale = Order[order.id]
      order.mark_paid!(paid_amount: 15_000)
      allow_any_instance_of(MWallet::Client).to receive(:cancel_invoice).and_return({})

      MWallet::Service.new.cancel_invoice_for_order(stale)

      expect(order.refresh.status).to eq(OrderStatus::PAID)
    end
  end
end
