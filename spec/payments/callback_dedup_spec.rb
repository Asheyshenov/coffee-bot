# frozen_string_literal: true

require_relative 'payments_helper'

RSpec.describe 'Payments: MWallet callback endpoint' do
  include_context 'payments sandbox'
  include Rack::Test::Methods

  def app = CoffeeBot::HTTP::CallbackApp

  before { CoffeeBot::HTTP::CallbackApp.set :host_authorization, { permitted_hosts: [] } }

  def post_callback(body, content_type: 'application/json')
    post '/callbacks/mwallet/result', body, 'CONTENT_TYPE' => content_type
  end

  describe 'deduplication' do
    it 'ignores an identical repeated callback body (processed once, notified once)' do
      order = make_order(invoice: 'INV-DUP')
      body = signed_body({ 'invoice_id' => 'INV-DUP', 'status' => 3, 'amount' => 15_000 })

      2.times do
        post_callback(body)
        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)['status']).to eq('ok')
      end

      expect(order.refresh.status).to eq(OrderStatus::PAID)
      logs = CallbackLog.by_invoice_id('INV-DUP').order(:id).all
      expect(logs.size).to eq(2)
      expect(logs.map(&:process_error)).to eq([nil, CallbackLog::DUPLICATE_ERROR])
      expect(logs.map(&:event_id)).to all(be_nil)
      expect(api.messages_to(PaymentsSpec::CLIENT_ID).size).to eq(1)
      expect(api.messages_to(PaymentsSpec::BARISTA_ID).size).to eq(1)
    end

    it 'processes a provider retry of the same body after a failed attempt' do
      order = make_order(invoice: 'INV-RETRY')
      body = signed_body({ 'invoice_id' => 'INV-RETRY', 'status' => 3, 'amount' => 15_000 })
      calls = 0
      allow_any_instance_of(Order).to receive(:mark_paid!).and_wrap_original do |original, *args|
        calls += 1
        raise Sequel::DatabaseError, 'database is locked' if calls == 1

        original.call(*args)
      end

      post_callback(body)
      expect(order.refresh.status).to eq(OrderStatus::INVOICE_CREATED)
      post_callback(body)

      expect(order.refresh.status).to eq(OrderStatus::PAID)
    end

    it 'does not count callbacks with an invalid signature as handled' do
      make_order(invoice: 'INV-SIG')
      forged = { 'invoice_id' => 'INV-SIG', 'status' => 3, 'hash' => 'deadbeef' }.to_json

      post_callback(forged)

      expect(last_response.status).to eq(401)
      expect(CallbackLog.duplicate?(nil, 'INV-SIG', forged)).to be(false)
    end
  end

  describe 'request handling' do
    it 'returns 400 for an empty body' do
      post_callback('')
      expect(last_response.status).to eq(400)
    end

    it 'returns 400 for malformed JSON' do
      post_callback('{"invoice_id": ')
      expect(last_response.status).to eq(400)
    end

    it 'returns 400 for a JSON body that is not an object' do
      post_callback('[1, 2, 3]')
      expect(last_response.status).to eq(400)
    end

    it 'acknowledges a callback for an unknown invoice with 200' do
      post_callback(signed_body({ 'invoice_id' => 'INV-UNKNOWN', 'status' => 3, 'amount' => 15_000 }))
      expect(last_response.status).to eq(200)
    end

    it 'exits the notification thread cleanly (no LocalJumpError) when the order is gone' do
      order = make_order(invoice: 'INV-GONE')
      allow(Order).to receive(:[]).and_call_original
      allow(Order).to receive(:[]).with(order.id).and_return(nil) # no DB access in the thread
      threads = []
      allow(Thread).to receive(:new).and_wrap_original { |m, *args, &blk| m.call(*args, &blk).tap { |t| threads << t } }
      errors = []
      allow(CoffeeBot::LOG).to receive(:error) { |msg| errors << msg }

      post_callback(signed_body({ 'invoice_id' => 'INV-GONE', 'status' => 3, 'amount' => 15_000 }))
      threads.each(&:join)

      expect(last_response.status).to eq(200)
      expect(errors).to include(hash_including(message: 'Cannot send payment notifications: order not found'))
      expect(errors.to_s).not_to match(/unexpected return|LocalJumpError/)
      expect(api.calls).to be_empty
    end

    it 'never exposes exception details in the response body' do
      allow(CoffeeBot::Services::OrderService).to receive(:process_payment_callback)
        .and_raise(StandardError, 'SQLite3::Secret orders.raw_create_response')

      post_callback(signed_body({ 'invoice_id' => 'INV-X', 'status' => 3 }))

      expect(last_response.body).not_to include('Secret')
      expect(JSON.parse(last_response.body)).to eq('status' => 'error')
    end
  end
end
