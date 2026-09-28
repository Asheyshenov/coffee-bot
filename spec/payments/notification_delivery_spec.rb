# frozen_string_literal: true

require "rails_helper"

# Payment notifications are sent only by the caller that won the status transition,
# so a Telegram failure on one message must not swallow the others.
RSpec.describe "Payments: notification delivery" do
  # Telegram API fake that fails for selected chats the way telegram-bot-ruby 2.4 does
  # on network problems (Faraday errors are not wrapped in ResponseError)
  let(:failing_chats) { {} }
  let(:telegram) do
    chats = failing_chats
    Class.new(FakeTelegramApi) do
      define_method(:send_message) do |**kwargs|
        error = chats[kwargs[:chat_id]]
        raise error if error

        @calls << [ :send_message, kwargs ]
        { "ok" => true }
      end
    end.new
  end
  let(:notifier) { Notifier.for(current_tenant) }
  let(:paid_result) { ->(order) { { updated: true, order_id: order.id, notify_barista: true } } }

  before { allow_any_instance_of(Bot).to receive(:api).and_return(telegram) }

  def texts_for(chat_id) = telegram.messages_to(chat_id).map { |m| m[:text] }

  def paid_order
    make_order.tap { |order| order.mark_paid!(paid_amount: 15_000) }
  end

  describe "Notifier#notify_payment_result" do
    it "still tells baristas about the order when the client message times out" do
      failing_chats[client_id] = Faraday::TimeoutError.new("execution expired")
      order = paid_order

      expect { notifier.notify_payment_result(order, paid_result.call(order)) }.not_to raise_error
      expect(texts_for(barista_id).join).to include("Новый заказ ##{order.id}")
    end

    it "still confirms the payment to the client when the barista message fails" do
      failing_chats[barista_id] = Faraday::ConnectionFailed.new("connection refused")
      order = paid_order

      expect { notifier.notify_payment_result(order, paid_result.call(order)) }.not_to raise_error
      expect(texts_for(client_id).join).to include("Оплата прошла успешно")
    end

    it "sends the barista notification first, with the claim button" do
      order = paid_order

      notifier.notify_payment_result(order, paid_result.call(order))

      expect(telegram.calls.map { |(_, kw)| kw[:chat_id] }).to eq([ barista_id, client_id ])
      button = telegram.messages_to(barista_id).first[:reply_markup].inline_keyboard.flatten.first
      expect(button.callback_data).to eq("barista_claim_#{order.id}")
      expect(order.reload.last_notified_status).to eq(OrderStatus::PAID)
    end

    it "does not lose the barista notification when recording last_notified_status fails" do
      order = paid_order
      allow(order).to receive(:update_column).and_raise(ActiveRecord::StatementInvalid, "deadlock detected")

      expect { notifier.notify_payment_result(order, paid_result.call(order)) }.not_to raise_error
      expect(texts_for(barista_id).join).to include("Новый заказ ##{order.id}")
      expect(texts_for(client_id).join).to include("Оплата прошла успешно")
    end

    it "notifies every active staff member of the shop, and only them" do
      StaffMember.create!(telegram_user_id: 5005, role: "manager")
      StaffMember.create!(telegram_user_id: 6006, role: "barista", active: false)
      ActsAsTenant.with_tenant(other_tenant(barista_ids: [ 7007 ])) { nil }
      order = paid_order

      notifier.notify_payment_result(order, paid_result.call(order))

      expect(telegram.messages_to(barista_id)).to be_present
      expect(telegram.messages_to(5005)).to be_present
      expect(telegram.messages_to(6006)).to be_empty
      expect(telegram.messages_to(7007)).to be_empty
    end

    describe "notify_client: false (the caller answers the client itself)" do
      it "only tells staff about a paid order" do
        order = paid_order

        notifier.notify_payment_result(order, paid_result.call(order), notify_client: false)

        expect(texts_for(barista_id).join).to include("Новый заказ ##{order.id}")
        expect(texts_for(client_id)).to be_empty
        expect(order.reload.last_notified_status).to eq(OrderStatus::PAID)
      end

      it "only alerts staff about a payment problem" do
        order = make_order(total: 50_000)

        notifier.notify_payment_result(order, { payment_error: "amount_mismatch", expected_amount: 50_000, paid_amount: "100" },
                                       notify_client: false)

        expect(texts_for(barista_id).join).to include("Проблема с оплатой заказа ##{order.id}", "500.00 KGS", "1.00 KGS")
        expect(texts_for(client_id)).to be_empty
      end

      it "still announces a refund in full" do
        order = make_order(status: OrderStatus::EXPIRED)

        notifier.notify_payment_result(order, { refund_required: true, paid_amount: 15_000, previous_status: "EXPIRED" },
                                       notify_client: false)

        expect(texts_for(barista_id).join).to include("Требуется возврат")
        expect(texts_for(client_id).join).to include("деньги вернём")
      end
    end
  end

  describe "Notifier#send_to_client" do
    it "returns false instead of raising when Telegram is unreachable" do
      failing_chats[client_id] = Faraday::ConnectionFailed.new("getaddrinfo failed")

      expect(notifier.send_to_client(client_id, "hi")).to be(false)
    end

    it "returns false when Telegram rejects the message" do
      response = Struct.new(:status, :body, :env).new(403, '{"ok":false,"error_code":403,"description":"bot was blocked"}', nil)
      failing_chats[client_id] = Telegram::Bot::Exceptions::ResponseError.new(response: response)

      expect(notifier.send_to_client(client_id, "hi")).to be(false)
    end

    it "returns false when the shop has no active bot" do
      current_tenant.bots.update_all(active: false)

      expect(Notifier.for(current_tenant.reload).send_to_client(client_id, "hi")).to be(false)
    end
  end

  describe "Notifier#send_payment_qr" do
    it "tells the payment time of the shop and offers the pay / check buttons" do
      current_tenant.update!(order_expire_minutes: 7)
      order = make_order

      # The QR image download hits the network kill switch: the text still goes out
      notifier.send_payment_qr(order, { paylink_url: "https://pay.test/1", emv_qr_url: "https://qr.test/1.png" })

      message = telegram.messages_to(client_id).sole
      expect(message[:text]).to include("Оплатить в течение 7 минут", order.formatted_total)
      buttons = message[:reply_markup].inline_keyboard.flatten
      expect(buttons.map(&:url).compact).to eq([ "https://pay.test/1" ])
      expect(buttons.map(&:callback_data).compact).to eq([ "check_payment_#{order.id}" ])
    end

    it "uploads the QR image from base64 when there is no image URL" do
      order = make_order

      notifier.send_payment_qr(order, { paylink_url: "https://pay.test/1", qr_image_base64: Base64.strict_encode64("PNG") })

      photo = telegram.of(:send_photo).sole
      expect(photo).to include(chat_id: client_id, caption: "QR-код для оплаты")
      expect(photo[:photo].read).to eq("PNG")
    end
  end

  describe "callback endpoint", type: :request do
    it "notifies baristas about a paid order even if the client message times out" do
      failing_chats[client_id] = Faraday::TimeoutError.new("execution expired")
      order = make_order(invoice: "INV-NOTIFY")
      provider_confirms

      post_callback(signed_body({ "invoice_id" => "INV-NOTIFY", "status" => 3, "amount" => 15_000 }))
      perform_notifications

      expect(response).to have_http_status(:ok)
      expect(order.reload.status).to eq(OrderStatus::PAID)
      expect(texts_for(barista_id).join).to include("Новый заказ ##{order.id}")
    end
  end
end
