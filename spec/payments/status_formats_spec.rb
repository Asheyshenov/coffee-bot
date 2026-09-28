# frozen_string_literal: true

require_relative 'payments_helper'

# Merchants differ: some return text statuses ("approved", "processing"),
# others numeric codes, and the status may sit in data.status or in data.payments[].
RSpec.describe 'Payments: provider status formats' do
  include_context 'payments sandbox'

  def provider_returns(data)
    allow_any_instance_of(MWallet::Client).to receive(:get_status).and_return({ 'data' => data })
  end

  describe 'statusPayment' do
    it 'keeps waiting on the real sandbox response for an unpaid invoice ({"status":"processing"})' do
      order = make_order
      provider_returns('status' => 'processing')

      result = MWallet::Service.new.sync_status(order)

      expect(result[:updated]).to be(false)
      expect(order.refresh.status).to eq(OrderStatus::INVOICE_CREATED)
    end

    {
      'text in data.status' => { 'status' => 'approved', 'amount' => 15_000 },
      'code in data.status' => { 'status' => 3, 'amount' => 15_000 },
      'numeric string in data.status' => { 'status' => '3', 'amount' => '15000' },
      'numeric string in data.payments[]' => { 'payments' => [{ 'status' => '3', 'amount' => '15000' }] }
    }.each do |label, data|
      it "marks the order paid for #{label}" do
        order = make_order
        provider_returns(data)

        MWallet::Service.new.sync_status(order)

        expect(order.refresh.status).to eq(OrderStatus::PAID)
      end
    end

    it 'cancels an unpaid invoice for code 2 sent as a string' do
      order = make_order
      provider_returns('status' => '2')

      MWallet::Service.new.sync_status(order)

      expect(order.refresh.status).to eq(OrderStatus::CANCELLED)
    end

    it 'ignores an unknown status and logs the raw value' do
      order = make_order
      provider_returns('status' => 'on_hold_by_bank')
      expect(CoffeeBot::LOG).to receive(:warn).with(hash_including(provider_status: '"on_hold_by_bank"'))

      result = MWallet::Service.new.sync_status(order)

      expect(result[:updated]).to be(false)
      expect(order.refresh.status).to eq(OrderStatus::INVOICE_CREATED)
    end
  end

  describe 'callback' do
    include Rack::Test::Methods
    def app = CoffeeBot::HTTP::CallbackApp

    before { CoffeeBot::HTTP::CallbackApp.set :host_authorization, { permitted_hosts: [] } }

    it 'accepts a numeric-string status code ("3")' do
      order = make_order(invoice: 'INV-FMT-1')

      post '/callbacks/mwallet/result',
           signed_body({ 'invoice_id' => 'INV-FMT-1', 'status' => '3', 'amount' => '15000' }),
           'CONTENT_TYPE' => 'application/json'

      expect(order.refresh.status).to eq(OrderStatus::PAID)
    end

    it 'accepts a text status ("approved")' do
      order = make_order(invoice: 'INV-FMT-2')

      post '/callbacks/mwallet/result',
           signed_body({ 'invoice_id' => 'INV-FMT-2', 'status' => 'approved', 'amount' => 15_000 }),
           'CONTENT_TYPE' => 'application/json'

      expect(order.refresh.status).to eq(OrderStatus::PAID)
    end
  end
end
