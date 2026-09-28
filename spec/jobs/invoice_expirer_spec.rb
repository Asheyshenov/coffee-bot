# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../lib/jobs/invoice_expirer'

RSpec.describe CoffeeBot::Jobs::InvoiceExpirer do
  let(:client_id) { 1001 }
  let(:notifier) do
    instance_double(CoffeeBot::Services::Notifier,
      notify_invoice_expired: true,
      notify_payment_result: nil
    )
  end
  let(:expirer) { described_class.new(expire_minutes: 15, notifier: notifier) }

  before do
    # Hard network kill switch: nothing may leave the test process
    allow_any_instance_of(Faraday::Connection).to receive(:run_request).and_raise('NETWORK DISABLED IN TESTS')
  end

  def overdue_order(invoice: 'INV-EXP-1', total: 15_000, age_minutes: 60)
    order = Order.create(
      telegram_user_id: client_id,
      client_display_name: 'Test',
      status: OrderStatus::INVOICE_CREATED,
      total_amount: total,
      currency: 'KGS',
      merchant_invoice_id: Order.generate_merchant_invoice_id,
      invoice_id_provider: invoice,
      provider: 'MWALLET'
    )
    order.this.update(created_at: Time.now.utc - (age_minutes * 60))
    order
  end

  def same_order(order)
    an_object_having_attributes(id: order.id)
  end

  describe '#run_once' do
    it 'cancels the invoice at the provider, marks the order EXPIRED and notifies the client' do
      order = overdue_order
      expect_any_instance_of(MWallet::Client).to receive(:cancel_invoice).with('INV-EXP-1').and_return({})

      expect(expirer.run_once).to eq(1)

      order.refresh
      expect(order.status).to eq(OrderStatus::EXPIRED)
      expect(order.last_notified_status).to eq(OrderStatus::EXPIRED)
      expect(notifier).to have_received(:notify_invoice_expired).with(same_order(order)).once
    end

    it 'leaves invoices that are not overdue yet alone' do
      order = overdue_order(age_minutes: 5)
      expect_any_instance_of(MWallet::Client).not_to receive(:cancel_invoice)

      expect(expirer.run_once).to eq(0)

      expect(order.refresh.status).to eq(OrderStatus::INVOICE_CREATED)
      expect(notifier).not_to have_received(:notify_invoice_expired)
    end

    it 'expires anyway when the last-chance payment check cannot reach the provider' do
      order = overdue_order # get_status hits the network kill switch (RuntimeError)
      allow_any_instance_of(MWallet::Client).to receive(:cancel_invoice).and_return({})

      expect(expirer.run_once).to eq(1)

      expect(order.refresh.status).to eq(OrderStatus::EXPIRED)
      expect(notifier).to have_received(:notify_invoice_expired).with(same_order(order))
    end

    it 'builds the notifier lazily from the Telegram bot token' do
      order = overdue_order
      allow_any_instance_of(MWallet::Client).to receive(:cancel_invoice).and_return({})
      api = double('telegram api', send_message: { 'ok' => true })
      allow(Telegram::Bot::Client).to receive(:new).and_return(double('bot', api: api))

      described_class.new(expire_minutes: 15).run_once

      expect(order.refresh.status).to eq(OrderStatus::EXPIRED)
      expect(api).to have_received(:send_message).with(hash_including(chat_id: client_id))
    end

    it 'processes at most BATCH_SIZE orders per run, oldest first' do
      stub_const("#{described_class}::BATCH_SIZE", 1)
      older = overdue_order(invoice: 'INV-OLD', age_minutes: 120)
      newer = overdue_order(invoice: 'INV-NEW', age_minutes: 60)
      allow_any_instance_of(MWallet::Client).to receive(:cancel_invoice).and_return({})

      expect(expirer.run_once).to eq(1)
      expect(older.refresh.status).to eq(OrderStatus::EXPIRED)
      expect(newer.refresh.status).to eq(OrderStatus::INVOICE_CREATED)

      expect(expirer.run_once).to eq(1)
      expect(newer.refresh.status).to eq(OrderStatus::EXPIRED)
    end
  end

  context 'when the order turns out to be paid at the last moment' do
    let(:barista_id) { 2002 }
    let(:recipients) { [] }
    let(:api) do
      double('telegram api').tap do |api|
        allow(api).to receive(:send_message) do |**kw|
          recipients << kw[:chat_id]
          { 'ok' => true }
        end
      end
    end
    let(:real_notifier) { CoffeeBot::Services::Notifier.new(double('bot', api: api)) }

    before do
      stub_const('CoffeeBot::Config::BARISTA_WHITELIST', [barista_id])
      allow_any_instance_of(MWallet::Client).to receive(:get_status)
        .and_return({ 'data' => { 'payments' => [{ 'status' => 'approved', 'amount' => 15_000 }] } })
    end

    it 'skips expiry and notifies the client and the baristas about the payment' do
      order = overdue_order
      expect_any_instance_of(MWallet::Client).not_to receive(:cancel_invoice)

      expect(described_class.new(expire_minutes: 15, notifier: real_notifier).run_once).to eq(0)

      expect(order.refresh.status).to eq(OrderStatus::PAID)
      expect(recipients).to include(client_id, barista_id)
    end

    it 'keeps the order paid when sending the payment notifications fails' do
      order = overdue_order
      allow(notifier).to receive(:notify_payment_result).and_raise(StandardError, 'telegram down')

      expect(expirer.run_once).to eq(0)

      expect(order.refresh.status).to eq(OrderStatus::PAID)
      expect(notifier).not_to have_received(:notify_invoice_expired)
    end
  end

  context 'when the last-chance check finds a payment problem' do
    let(:result) do
      { updated: true, order_id: nil, notify_barista: false, payment_error: 'amount_mismatch',
        expected_amount: 15_000, paid_amount: 100 }
    end

    before do
      allow(CoffeeBot::Services::OrderService).to receive(:sync_payment_status) do |order|
        order.this.update(status: OrderStatus::ERROR)
        result.merge(order_id: order.id)
      end
    end

    it 'passes the result to the notifier and does not expire or cancel the invoice' do
      order = overdue_order
      expect_any_instance_of(MWallet::Client).not_to receive(:cancel_invoice)

      expect(expirer.run_once).to eq(0)

      expect(order.refresh.status).to eq(OrderStatus::ERROR)
      expect(notifier).to have_received(:notify_payment_result)
        .with(same_order(order), hash_including(payment_error: 'amount_mismatch'))
      expect(notifier).not_to have_received(:notify_invoice_expired)
    end
  end

  context 'when the provider already closed the invoice during the payment check' do
    before do
      allow(CoffeeBot::Services::OrderService).to receive(:sync_payment_status) do |order|
        order.update(status: OrderStatus::CANCELLED)
        { updated: true, order_id: order.id, notify_barista: false }
      end
    end

    it 'does not expire or cancel again, but tells the client once' do
      order = overdue_order
      expect_any_instance_of(MWallet::Client).not_to receive(:cancel_invoice)

      expect(expirer.run_once).to eq(0)

      order.refresh
      expect(order.status).to eq(OrderStatus::CANCELLED)
      expect(order.last_notified_status).to eq(OrderStatus::CANCELLED)
      expect(notifier).to have_received(:notify_invoice_expired).with(same_order(order)).once
    end
  end

  context 'when cancelling the invoice at the provider fails' do
    it 'still expires the order and notifies the client' do
      order = overdue_order
      allow_any_instance_of(MWallet::Client).to receive(:cancel_invoice)
        .and_raise(MWalletError::NetworkError.new('Network error: connection refused'))

      expect(expirer.run_once).to eq(1)

      order.refresh
      expect(order.status).to eq(OrderStatus::EXPIRED)
      expect(order.last_notified_status).to eq(OrderStatus::EXPIRED)
      expect(notifier).to have_received(:notify_invoice_expired).with(same_order(order))
    end

    it 'handles unexpected (non-MWallet) errors the same way' do
      order = overdue_order # cancel_invoice hits the network kill switch (RuntimeError)

      expect(expirer.run_once).to eq(1)

      expect(order.refresh.status).to eq(OrderStatus::EXPIRED)
    end
  end

  context 'when expire! loses a race' do
    it 'does not notify when a callback marked the order PAID during the provider call' do
      order = overdue_order
      allow_any_instance_of(MWallet::Client).to receive(:cancel_invoice) do
        order.this.update(status: OrderStatus::PAID) # concurrent callback
        {}
      end

      expect(expirer.run_once).to eq(0)

      order.refresh
      expect(order.status).to eq(OrderStatus::PAID)
      expect(order.last_notified_status).to be_nil
      expect(notifier).not_to have_received(:notify_invoice_expired)
    end

    it 'never overwrites a payment committed after the last re-read (conditional UPDATE in expire!)' do
      order = overdue_order
      allow_any_instance_of(MWallet::Client).to receive(:cancel_invoice).and_return({})
      allow_any_instance_of(Order).to receive(:expire!).and_wrap_original do |original, *args|
        # The job has already re-read the order: in memory it is still INVOICE_CREATED
        expect(original.receiver.status).to eq(OrderStatus::INVOICE_CREATED)
        # ...and right now the callback process commits the payment
        expect(Order[order.id].mark_paid!(paid_amount: 15_000)).to be(true)
        original.call(*args)
      end

      expect(expirer.run_once).to eq(0)

      order.refresh
      expect(order.status).to eq(OrderStatus::PAID)
      expect(order.payment.status).to eq(PaymentStatus::PAID)
      expect(order.last_notified_status).to be_nil
      expect(notifier).not_to have_received(:notify_invoice_expired)
    end

    it 'does not notify when expire! reports that the status changed' do
      order = overdue_order
      allow_any_instance_of(MWallet::Client).to receive(:cancel_invoice).and_return({})
      allow_any_instance_of(Order).to receive(:expire!).and_return(false)

      expect(expirer.run_once).to eq(0)

      expect(order.refresh.last_notified_status).to be_nil
      expect(notifier).not_to have_received(:notify_invoice_expired)
    end
  end

  context 'when notifying the client fails' do
    it 'keeps the order EXPIRED, leaves it unmarked as notified and continues with the batch' do
      first = overdue_order(invoice: 'INV-A', age_minutes: 120)
      second = overdue_order(invoice: 'INV-B', age_minutes: 60)
      allow_any_instance_of(MWallet::Client).to receive(:cancel_invoice).and_return({})
      allow(notifier).to receive(:notify_invoice_expired).and_raise(StandardError, 'telegram down')

      expect(expirer.run_once).to eq(2)

      [first, second].each do |order|
        order.refresh
        expect(order.status).to eq(OrderStatus::EXPIRED)
        expect(order.last_notified_status).to be_nil
      end
    end
  end

  describe '#start / #stop' do
    it 'keeps the loop alive when a run raises and stops on request' do
      job = described_class.new(interval_seconds: 0.01, notifier: notifier)
      runs = 0
      allow(job).to receive(:run_once) do
        runs += 1
        raise StandardError, 'boom'
      end

      thread = job.start
      deadline = Time.now + 2
      sleep 0.01 until runs >= 2 || Time.now > deadline
      expect(runs).to be >= 2 # kept looping after the first failed run
      expect(thread).to be_alive
      expect(job.start).to be_nil # already running

      job.stop
      expect(thread.join(1)).to eq(thread)
    end
  end
end
