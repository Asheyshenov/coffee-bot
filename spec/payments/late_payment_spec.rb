# frozen_string_literal: true

require_relative 'payments_helper'

RSpec.describe 'Payments: late payments (after EXPIRED / CANCELLED)' do
  include_context 'payments sandbox'

  describe 'via callback' do
    include Rack::Test::Methods
    def app = CoffeeBot::HTTP::CallbackApp

    before { CoffeeBot::HTTP::CallbackApp.set :host_authorization, { permitted_hosts: [] } }

    def post_paid_callback(invoice, amount: 15_000)
      post '/callbacks/mwallet/result',
           signed_body({ 'invoice_id' => invoice, 'status' => 3, 'amount' => amount }),
           'CONTENT_TYPE' => 'application/json'
    end

    it 'does not fulfil a payment for an EXPIRED order: records a refund, tells client and baristas' do
      order = make_order(status: OrderStatus::EXPIRED, invoice: 'INV-LATE-1')

      post_paid_callback('INV-LATE-1')

      expect(last_response.status).to eq(200)
      expect(order.refresh.status).to eq(OrderStatus::EXPIRED)
      expect(Payment.where(order_id: order.id, status: PaymentStatus::REFUND_REQUIRED).count).to eq(1)
      expect(order.refund_required?).to be(true)

      client_text = api.messages_to(PaymentsSpec::CLIENT_ID).join
      expect(client_text).to include("Оплата по заказу ##{order.id} поступила после истечения срока счёта", 'деньги вернём')
      expect(client_text).not_to include('передан в работу')
      barista_text = api.messages_to(PaymentsSpec::BARISTA_ID).join
      expect(barista_text).to include("Требуется возврат по заказу ##{order.id}", 'INV-LATE-1', '150.00 KGS')
      expect(barista_text).not_to include('Новый заказ')
    end

    it 'records a refund for a CANCELLED order with a "после отмены" reason' do
      order = make_order(status: OrderStatus::CANCELLED, invoice: 'INV-LATE-2')

      post_paid_callback('INV-LATE-2')

      expect(order.refresh.status).to eq(OrderStatus::CANCELLED)
      expect(api.messages_to(PaymentsSpec::BARISTA_ID).join).to include('Клиент оплатил после отмены заказа')
    end

    it 'refunds whatever was paid for a late payment, even below the total' do
      order = make_order(status: OrderStatus::EXPIRED, total: 50_000, invoice: 'INV-LATE-3')

      post_paid_callback('INV-LATE-3', amount: 100)

      expect(order.refresh.status).to eq(OrderStatus::EXPIRED)
      expect(Payment.where(order_id: order.id).get(:paid_amount)).to eq(100)
      expect(api.messages_to(PaymentsSpec::BARISTA_ID).join).to include('Оплачено: 1.00 KGS')
    end

    it 'requests the refund only once when the provider repeats the callback' do
      order = make_order(status: OrderStatus::EXPIRED, invoice: 'INV-LATE-5')

      post_paid_callback('INV-LATE-5')
      post '/callbacks/mwallet/result',
           signed_body({ 'invoice_id' => 'INV-LATE-5', 'status' => '3', 'amount' => '15000.00' }),
           'CONTENT_TYPE' => 'application/json'

      expect(Payment.where(order_id: order.id).count).to eq(1)
      expect(api.messages_to(PaymentsSpec::BARISTA_ID).join.scan('Требуется возврат').size).to eq(1)
    end

    it 'never resurrects an order that was paid and then cancelled (refund case)' do
      order = make_order(status: OrderStatus::CANCELLED, invoice: 'INV-LATE-4')
      Payment.create(order_id: order.id, invoice_id_provider: 'INV-LATE-4', paid_amount: 15_000,
                     status: PaymentStatus::REFUNDED_FULL)

      post_paid_callback('INV-LATE-4')

      expect(order.refresh.status).to eq(OrderStatus::CANCELLED)
      expect(api.calls).to be_empty
    end
  end

  describe 'via polling' do
    it 'sync_status reports a required refund for an EXPIRED order' do
      order = make_order(status: OrderStatus::EXPIRED)
      stub_provider_status(status: 'approved', amount: 15_000)

      result = CoffeeBot::Services::OrderService.sync_payment_status(order)

      expect(result).to include(updated: true, order_id: order.id, notify_barista: false, late_payment: true,
                                refund_required: true, previous_status: OrderStatus::EXPIRED, paid_amount: 15_000)
      expect(order.refresh.status).to eq(OrderStatus::EXPIRED)
    end

    it 'prefers an approved payment over an earlier rejected attempt' do
      order = make_order(status: OrderStatus::EXPIRED)
      allow_any_instance_of(MWallet::Client).to receive(:get_status).and_return(
        { 'data' => { 'payments' => [{ 'status' => 'rejected', 'amount' => '15000' },
                                     { 'status' => 'approved', 'amount' => '15000' }] } }
      )

      MWallet::Service.new.sync_status(order)

      expect(order.refund_required?).to be(true)
    end

    it 'turns a payment that loses the race against the expirer into a refund' do
      order = make_order(invoice: 'INV-RACE') # INVOICE_CREATED in memory
      stub_provider_status(status: 'approved', amount: 15_000)
      Order.where(id: order.id).update(status: OrderStatus::EXPIRED) # expirer got there first

      result = MWallet::Service.new.sync_status(order)

      expect(result).to include(updated: true, refund_required: true, previous_status: OrderStatus::EXPIRED)
      expect(order.refresh.status).to eq(OrderStatus::EXPIRED)
      expect(Payment.where(order_id: order.id).get(:status)).to eq(PaymentStatus::REFUND_REQUIRED)
    end
  end

  describe CoffeeBot::Jobs::StatusSyncer do
    let(:syncer) { described_class.new(late_payment_interval_seconds: 60) }
    let(:polled_ids) { [] }

    before do
      allow(CoffeeBot::Services::OrderService).to receive(:sync_payment_status) do |order|
        polled_ids << order.id
        { updated: false, order_id: order.id, notify_barista: false }
      end
    end

    it 'polls recent EXPIRED/CANCELLED orders with an invoice and no settled payment' do
      expired = make_order(status: OrderStatus::EXPIRED, invoice: 'INV-C-1')
      cancelled = make_order(status: OrderStatus::CANCELLED, invoice: 'INV-C-2')
      no_invoice = make_order(status: OrderStatus::EXPIRED, invoice: nil)
      too_old = make_order(status: OrderStatus::EXPIRED, invoice: 'INV-C-3')
      too_old.this.update(updated_at: Time.now.utc - (25 * 3600))
      already_paid = make_order(status: OrderStatus::CANCELLED, invoice: 'INV-C-4')
      Payment.create(order_id: already_paid.id, paid_amount: 15_000, status: PaymentStatus::PAID)

      syncer.run_once

      expect(polled_ids).to contain_exactly(expired.id, cancelled.id)
      expect(polled_ids).not_to include(no_invoice.id, too_old.id, already_paid.id)
    end

    it 'polls late-payment candidates at a lower frequency than active invoices' do
      active = make_order(invoice: 'INV-ACTIVE')
      expired = make_order(status: OrderStatus::EXPIRED, invoice: 'INV-EXP')
      clock = 1_000.0
      allow(syncer).to receive(:monotonic_now) { clock }

      syncer.run_once
      clock += 2
      syncer.run_once
      clock += 60
      syncer.run_once

      expect(polled_ids.count(active.id)).to eq(3)
      expect(polled_ids.count(expired.id)).to eq(2)
    end

    it 'postpones the rest of the late-payment batch when the provider is unreachable' do
      make_order(status: OrderStatus::EXPIRED, invoice: 'INV-DOWN-1')
      make_order(status: OrderStatus::EXPIRED, invoice: 'INV-DOWN-2')
      allow(CoffeeBot::Services::OrderService).to receive(:sync_payment_status) do |order|
        polled_ids << order.id
        raise MWalletError::ProviderTimeout, 'timeout'
      end

      expect { syncer.run_once }.not_to raise_error
      expect(polled_ids.size).to eq(1)
    end

    context 'with more candidates than fit into one batch' do
      let(:clock) { [1_000.0] }

      before do
        stub_const('CoffeeBot::Jobs::StatusSyncer::LATE_PAYMENT_BATCH', 2)
        allow(syncer).to receive(:monotonic_now) { clock.first }
      end

      # Runs the syncer once per late-payment interval, returns ids polled per run
      def late_runs(count)
        Array.new(count) do
          polled_ids.clear
          syncer.run_once
          clock[0] += 60
          polled_ids.dup
        end
      end

      it 'rotates through the whole window instead of re-checking the same orders' do
        ids = Array.new(5) { |i| make_order(status: OrderStatus::EXPIRED, invoice: "INV-ROT-#{i}").id }

        runs = late_runs(3)

        expect(runs).to eq([ids[0, 2], ids[2, 2], [ids[4], ids[0]]])
        expect(runs.flatten.uniq).to match_array(ids)
      end

      it 'does not starve the rest when one candidate keeps failing' do
        ids = Array.new(3) { |i| make_order(status: OrderStatus::CANCELLED, invoice: "INV-BAD-#{i}").id }
        allow(CoffeeBot::Services::OrderService).to receive(:sync_payment_status) do |order|
          polled_ids << order.id
          raise MWalletError::BusinessError, 'invoice cancelled' if order.id == ids.first

          { updated: false, order_id: order.id, notify_barista: false }
        end

        expect(late_runs(2).flatten.uniq).to match_array(ids)
      end

      it 'moves on after a candidate the provider times out on' do
        ids = Array.new(3) { |i| make_order(status: OrderStatus::EXPIRED, invoice: "INV-SLOW-#{i}").id }
        allow(CoffeeBot::Services::OrderService).to receive(:sync_payment_status) do |order|
          polled_ids << order.id
          raise MWalletError::ProviderTimeout, 'timeout' if order.id == ids.first

          { updated: false, order_id: order.id, notify_barista: false }
        end

        runs = late_runs(2)

        expect(runs.first).to eq([ids.first]) # rest of the batch postponed
        expect(runs.last).to eq(ids[1, 2])
      end
    end

    it 'sends refund notifications from the winning poll and stops polling the order' do
      allow(CoffeeBot::Services::OrderService).to receive(:sync_payment_status).and_call_original
      order = make_order(status: OrderStatus::EXPIRED, invoice: 'INV-LATE-POLL')
      stub_provider_status(status: 'approved', amount: 15_000)

      expect(syncer.run_once).to eq(1)

      expect(order.refresh.status).to eq(OrderStatus::EXPIRED)
      expect(api.messages_to(PaymentsSpec::CLIENT_ID).join).to include('деньги вернём')
      expect(api.messages_to(PaymentsSpec::BARISTA_ID).join).to include("Требуется возврат по заказу ##{order.id}")
      expect(syncer.send(:late_payment_candidates).map(&:id)).not_to include(order.id)
    end
  end
end
