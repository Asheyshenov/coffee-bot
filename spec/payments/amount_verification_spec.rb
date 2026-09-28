# frozen_string_literal: true

require_relative 'payments_helper'

RSpec.describe 'Payments: paid amount verification' do
  include_context 'payments sandbox'

  let(:syncer) { CoffeeBot::Jobs::StatusSyncer.new }

  describe 'partial payment via polling' do
    it 'moves the order to ERROR and alerts baristas exactly once' do
      order = make_order(total: 50_000)
      stub_provider_status(status: 'approved', amount: '100')

      2.times { syncer.run_once } # a second poll must not alert again

      expect(order.refresh.status).to eq(OrderStatus::ERROR)
      alerts = api.messages_to(PaymentsSpec::BARISTA_ID).grep(/⚠️ Проблема с оплатой заказа ##{order.id}/)
      expect(alerts.size).to eq(1)
      expect(alerts.first).to include('500.00 KGS', '1.00 KGS')
      expect(api.messages_to(PaymentsSpec::CLIENT_ID)).to be_empty
    end

    it 'stores the explanation and the actually paid amount' do
      order = make_order(total: 50_000)
      stub_provider_status(status: 'approved', amount: 100)

      MWallet::Service.new.sync_status(order)

      expect(order.refresh.invoice_status_raw).to include('AMOUNT_MISMATCH', '50000', '100')
      payment = Payment.where(order_id: order.id).first
      expect(payment.status).to eq(PaymentStatus::FAILED)
      expect(payment.paid_amount).to eq(100)
    end

    it 'logs an error with order id, expected and received amount' do
      order = make_order(total: 50_000)
      stub_provider_status(status: 'approved', amount: 100)
      logged = []
      allow_any_instance_of(MWallet::Service).to receive(:log_error) { |_, msg, ctx| logged << [msg, ctx] }

      MWallet::Service.new.sync_status(order)

      expect(logged.map(&:last)).to include(hash_including(order_id: order.id, expected: 50_000, got: 100))
    end

    it 'returns a payment_error result without notify_barista' do
      order = make_order(total: 50_000)
      stub_provider_status(status: 'approved', amount: 100)

      result = CoffeeBot::Services::OrderService.sync_payment_status(order)

      expect(result).to include(updated: true, order_id: order.id, notify_barista: false, payment_error: :amount_mismatch)
    end
  end

  describe 'accepted amounts' do
    {
      'exact Integer' => 15_000,
      'numeric String' => '15000',
      'decimal String' => '15000.00',
      'overpayment' => '20000'
    }.each do |label, amount|
      it "marks the order PAID for #{label} (#{amount.inspect})" do
        order = make_order(total: 15_000)
        stub_provider_status(status: 'approved', amount: amount)

        result = MWallet::Service.new.sync_status(order)

        expect(result).to include(updated: true, notify_barista: true)
        expect(order.refresh.status).to eq(OrderStatus::PAID)
      end
    end

    it 'rejects an amount one tyiyn short ("14999.99")' do
      order = make_order(total: 15_000)
      stub_provider_status(status: 'approved', amount: '14999.99')

      MWallet::Service.new.sync_status(order)

      expect(order.refresh.status).to eq(OrderStatus::ERROR)
    end

    it 'rejects an unparseable amount instead of guessing' do
      order = make_order(total: 15_000)
      stub_provider_status(status: 'approved', amount: 'abc')

      result = MWallet::Service.new.sync_status(order)

      expect(result).to include(payment_error: :amount_unparseable)
      expect(order.refresh.status).to eq(OrderStatus::ERROR)
    end

    it 'accepts a payment without any amount but logs a warning' do
      order = make_order(total: 15_000)
      stub_provider_status(status: 'approved')
      allow(CoffeeBot::LOG).to receive(:warn)

      MWallet::Service.new.sync_status(order)

      expect(order.refresh.status).to eq(OrderStatus::PAID)
      expect(CoffeeBot::LOG).to have_received(:warn).with(hash_including(order_id: order.id))
    end
  end

  describe 'partial payment via callback' do
    include Rack::Test::Methods
    def app = CoffeeBot::HTTP::CallbackApp

    before { CoffeeBot::HTTP::CallbackApp.set :host_authorization, { permitted_hosts: [] } }

    it 'does not mark PAID and alerts baristas once even if the callback is repeated' do
      order = make_order(total: 50_000, invoice: 'INV-PART')
      2.times do |i|
        body = signed_body({ 'invoice_id' => 'INV-PART', 'status' => 3, 'amount' => 100, 'mktime' => i.to_s })
        post '/callbacks/mwallet/result', body, 'CONTENT_TYPE' => 'application/json'
        expect(last_response.status).to eq(200)
      end

      expect(order.refresh.status).to eq(OrderStatus::ERROR)
      expect(api.messages_to(PaymentsSpec::BARISTA_ID).grep(/⚠️ Проблема с оплатой/).size).to eq(1)
    end
  end

  describe 'Payment.parse_amount' do
    it 'parses Integer, numeric strings and comma decimals' do
      expect(Payment.parse_amount(15_000)).to eq(BigDecimal('15000'))
      expect(Payment.parse_amount(' 15000.50 ')).to eq(BigDecimal('15000.5'))
      expect(Payment.parse_amount('15 000,00')).to eq(BigDecimal('15000'))
      expect(Payment.parse_amount(150.5)).to eq(BigDecimal('150.5'))
    end

    it 'returns nil for a missing amount and raises for garbage' do
      expect(Payment.parse_amount(nil)).to be_nil
      expect(Payment.parse_amount('')).to be_nil
      expect { Payment.parse_amount('abc') }.to raise_error(ArgumentError)
      expect { Payment.parse_amount('Infinity') }.to raise_error(ArgumentError)
      expect { Payment.parse_amount({}) }.to raise_error(ArgumentError)
    end
  end
end
