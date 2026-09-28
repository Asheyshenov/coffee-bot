# frozen_string_literal: true

require_relative 'payments_helper'

# Payment notifications are sent only by the caller that won the status transition,
# so a Telegram failure on one message must not swallow the others.
RSpec.describe 'Payments: notification delivery' do
  include_context 'payments sandbox'

  # Telegram API fake that fails for selected chats the way telegram-bot-ruby 2.4
  # does on network problems (Faraday errors are not wrapped in ResponseError)
  let(:failing_chats) { {} }
  let(:api) do
    chats = failing_chats
    Class.new(PaymentsSpec::RecordingApi) do
      define_method(:send_message) do |**kwargs|
        error = chats[kwargs[:chat_id]]
        raise error if error

        @calls << [:send_message, kwargs]
        { 'ok' => true }
      end
    end.new
  end

  let(:notifier) { CoffeeBot::Services::Notifier.new(PaymentsSpec::FakeBot.new(api)) }
  let(:paid_result) { ->(order) { { updated: true, order_id: order.id, notify_barista: true } } }

  describe 'Notifier#notify_payment_result' do
    it 'still tells baristas about the order when the client message times out' do
      failing_chats[PaymentsSpec::CLIENT_ID] = Faraday::TimeoutError.new('execution expired')
      order = make_order
      order.mark_paid!(paid_amount: 15_000)

      expect { notifier.notify_payment_result(order, paid_result.call(order)) }.not_to raise_error
      expect(api.messages_to(PaymentsSpec::BARISTA_ID).join).to include("Новый заказ ##{order.id}")
    end

    it 'still confirms the payment to the client when the barista message fails' do
      failing_chats[PaymentsSpec::BARISTA_ID] = Faraday::ConnectionFailed.new('connection refused')
      order = make_order
      order.mark_paid!(paid_amount: 15_000)

      expect { notifier.notify_payment_result(order, paid_result.call(order)) }.not_to raise_error
      expect(api.messages_to(PaymentsSpec::CLIENT_ID).join).to include('Оплата прошла успешно')
    end

    it 'sends the barista notification first' do
      order = make_order
      order.mark_paid!(paid_amount: 15_000)

      notifier.notify_payment_result(order, paid_result.call(order))

      chats = api.calls.map { |(_, kw)| kw[:chat_id] }
      expect(chats).to eq([PaymentsSpec::BARISTA_ID, PaymentsSpec::CLIENT_ID])
    end

    it 'does not lose the barista notification when recording last_notified_status fails' do
      order = make_order
      order.mark_paid!(paid_amount: 15_000)
      allow(order).to receive(:update).and_raise(Sequel::DatabaseError, 'database is locked')

      expect { notifier.notify_payment_result(order, paid_result.call(order)) }.not_to raise_error
      expect(api.messages_to(PaymentsSpec::BARISTA_ID).join).to include("Новый заказ ##{order.id}")
      expect(api.messages_to(PaymentsSpec::CLIENT_ID).join).to include('Оплата прошла успешно')
    end
  end

  describe 'Notifier#send_to_client' do
    it 'returns false instead of raising when Telegram is unreachable' do
      failing_chats[PaymentsSpec::CLIENT_ID] = Faraday::ConnectionFailed.new('getaddrinfo failed')

      expect(notifier.send_to_client(PaymentsSpec::CLIENT_ID, 'hi')).to be(false)
    end
  end

  describe 'callback endpoint' do
    include Rack::Test::Methods
    def app = CoffeeBot::HTTP::CallbackApp

    before { CoffeeBot::HTTP::CallbackApp.set :host_authorization, { permitted_hosts: [] } }

    it 'notifies baristas about a paid order even if the client message times out' do
      failing_chats[PaymentsSpec::CLIENT_ID] = Faraday::TimeoutError.new('execution expired')
      order = make_order(invoice: 'INV-NOTIFY')

      post '/callbacks/mwallet/result',
           signed_body({ 'invoice_id' => 'INV-NOTIFY', 'status' => 3, 'amount' => 15_000 }),
           'CONTENT_TYPE' => 'application/json'

      expect(last_response.status).to eq(200)
      expect(order.refresh.status).to eq(OrderStatus::PAID)
      expect(api.messages_to(PaymentsSpec::BARISTA_ID).join).to include("Новый заказ ##{order.id}")
    end
  end
end
