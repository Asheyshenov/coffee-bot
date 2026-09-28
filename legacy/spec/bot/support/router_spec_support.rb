# frozen_string_literal: true

# Shared helpers for router specs.
# Namespaced so they do not clash with the top-level fakes of the edge-case suite.

require 'telegram/bot'

# telegram-bot-ruby 2.4 autoloads its types; autoloading CallbackQuery before Message
# hits a circular MaybeInaccessibleMessage <-> Message reference (NameError, then
# RepeatedAttributeError on every retry). Loading Message first avoids it.
Telegram::Bot::Types::Message

module RouterSpecSupport
  # Records every Telegram API call. Like real Telegram, a second answer for the
  # same callback query is rejected (recorded as :answer_callback_query_rejected).
  class RecordingTelegramApi
    attr_reader :calls

    def initialize
      @calls = []
      @answered = {}
    end

    def method_missing(name, **kwargs)
      if name == :answer_callback_query
        id = kwargs[:callback_query_id]
        if @answered[id]
          @calls << [:answer_callback_query_rejected, kwargs]
          return { 'ok' => false }
        end
        @answered[id] = true
      end
      @calls << [name, kwargs]
      { 'ok' => true }
    end

    def respond_to_missing?(*) = true

    def of(name)
      calls.select { |(n, _)| n == name }.map(&:last)
    end

    def texts
      calls.map { |(_, kw)| kw[:text] }.compact
    end

    # Messages sent to a given chat
    def messages_to(chat_id)
      of(:send_message).select { |m| m[:chat_id] == chat_id }
    end
  end

  FakeBot = Struct.new(:api)

  def user(id) = { id: id, is_bot: false, first_name: "U#{id}" }
  def chat(id) = { id: id, type: 'private' }

  def text_msg(text, from: client_id)
    Telegram::Bot::Types::Message.new(message_id: rand(1..10_000), date: 0, chat: chat(from), from: user(from), text: text)
  end

  def cb(data, from: client_id, id: "q#{rand(1_000_000)}")
    Telegram::Bot::Types::CallbackQuery.new(
      id: id, from: user(from), chat_instance: 'x', data: data,
      message: { message_id: 77, date: 0, chat: chat(from) }
    )
  end

  def dispatch(update)
    router.send(:handle_message, update)
  end

  def make_order(status: OrderStatus::INVOICE_CREATED, user_id: client_id, total: 15_000, invoice: 'INV-1')
    order = Order.create(telegram_user_id: user_id, client_display_name: 'Test', status: status,
                         total_amount: total, currency: 'KGS', merchant_invoice_id: Order.generate_merchant_invoice_id,
                         invoice_id_provider: invoice)
    OrderItem.create(order_id: order.id, item_name: 'Латте', qty: 1, unit_price: total, line_total: total)
    order
  end

  # Stub the MWallet statusPayment response
  def provider_reports(status, amount: 15_000)
    allow_any_instance_of(MWallet::Client).to receive(:get_status)
      .and_return({ 'data' => { 'payments' => [{ 'status' => status, 'amount' => amount }] } })
  end

  def self.included(base)
    base.class_eval do
      let(:api) { RouterSpecSupport::RecordingTelegramApi.new }
      let(:router) { CoffeeBot::Bot::Router.new(RouterSpecSupport::FakeBot.new(api)) }
      let(:client_id) { 1001 }
      let(:barista_id) { 2002 }
      let(:stranger_id) { 3003 }

      before do
        # Nothing may leave the test process
        allow_any_instance_of(Faraday::Connection).to receive(:run_request).and_raise('NETWORK DISABLED IN TESTS')
        stub_const('CoffeeBot::Config::BARISTA_WHITELIST', [barista_id])
        allow(Telegram::Bot::Client).to receive(:new).and_return(RouterSpecSupport::FakeBot.new(api))
      end
    end
  end
end
