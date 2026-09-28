# frozen_string_literal: true

# Shared setup for payment specs: no network, recording Telegram fake,
# notification threads run inline.

require_relative '../spec_helper'
require_relative '../../lib/http/callback_app'
require_relative '../../lib/jobs/status_syncer'

module PaymentsSpec
  CLIENT_ID = 1001
  BARISTA_ID = 2002
  SECRET = 'test-secret'

  # Records every Telegram API call
  class RecordingApi
    attr_reader :calls

    def initialize
      @calls = []
    end

    def method_missing(name, **kwargs)
      @calls << [name, kwargs]
      { 'ok' => true }
    end

    def respond_to_missing?(*) = true

    def messages_to(chat_id)
      calls.select { |(n, kw)| n == :send_message && kw[:chat_id] == chat_id }.map { |(_, kw)| kw[:text] }
    end
  end

  FakeBot = Struct.new(:api)

  module Helpers
    def make_order(status: OrderStatus::INVOICE_CREATED, total: 15_000, invoice: 'INV-P-1')
      order = Order.create(telegram_user_id: CLIENT_ID, client_display_name: 'Test', status: status,
                           total_amount: total, currency: 'KGS',
                           merchant_invoice_id: Order.generate_merchant_invoice_id,
                           invoice_id_provider: invoice)
      OrderItem.create(order_id: order.id, item_name: 'Латте', qty: 1, unit_price: total, line_total: total)
      order
    end

    def signed_body(params)
      MWallet::Signer.new(SECRET).build_signed_request(params).to_json
    end

    def stub_provider_status(status:, amount: :none)
      payment = { 'status' => status }
      payment['amount'] = amount unless amount == :none
      allow_any_instance_of(MWallet::Client).to receive(:get_status)
        .and_return({ 'data' => { 'payments' => [payment] } })
    end
  end
end

RSpec.shared_context 'payments sandbox' do
  include PaymentsSpec::Helpers

  let(:api) { PaymentsSpec::RecordingApi.new }

  before do
    # Hard network kill switch: nothing may leave the test process
    allow_any_instance_of(Faraday::Connection).to receive(:run_request).and_raise('NETWORK DISABLED IN TESTS')
    allow(Telegram::Bot::Client).to receive(:new).and_return(PaymentsSpec::FakeBot.new(api))
    allow(Thread).to receive(:new) { |&blk| blk.call }
    stub_const('CoffeeBot::Config::BARISTA_WHITELIST', [PaymentsSpec::BARISTA_ID])
    stub_const('CoffeeBot::Config::MWALLET_PASSWORD', PaymentsSpec::SECRET)
  end
end
