# frozen_string_literal: true

require "rails_helper"

RSpec.describe "ShopBot::Router: check payment, /cancel and refunds" do
  include_context "shop bot"

  describe "check_payment_<id>" do
    it "notifies baristas once when the tap detects the payment, and not again on a repeated tap" do
      order = make_order
      provider_reports("approved")

      dispatch(cb("check_payment_#{order.id}"))
      expect(order.reload.status).to eq(OrderStatus::PAID)
      expect(api.of(:edit_message_text).last[:text]).to include("Оплата подтверждена")
      expect(barista_new_order_messages.size).to eq(1)
      # The client is answered in place, no separate "payment received" message
      expect(api.messages_to(client_id)).to be_empty

      dispatch(cb("check_payment_#{order.id}"))
      expect(barista_new_order_messages.size).to eq(1)
    end

    it "does not notify baristas again when polling already marked the order paid" do
      order = make_order
      provider_reports("approved")
      # Polling got there first (it sends its own notifications)
      OrderService.sync_payment_status(order)
      expect(order.reload.status).to eq(OrderStatus::PAID)

      dispatch(cb("check_payment_#{order.id}"))

      expect(barista_new_order_messages).to be_empty
      expect(api.of(:edit_message_text).last[:text]).to include("Оплата подтверждена")
    end

    it "does not even ask the provider when the order is already paid" do
      order = make_order(status: OrderStatus::PAID)
      expect_any_instance_of(MWallet::Client).not_to receive(:get_status)

      dispatch(cb("check_payment_#{order.id}"))

      expect(barista_new_order_messages).to be_empty
      expect(api.of(:edit_message_text).last[:text]).to include("Оплата подтверждена")
    end

    it "shows the status of an order that is already being prepared" do
      order = make_order(status: OrderStatus::IN_PROGRESS)

      dispatch(cb("check_payment_#{order.id}"))

      expect(api.of(:edit_message_text).last[:text]).to include("оплачен", OrderStatus.display_name(OrderStatus::IN_PROGRESS))
    end

    it 'shows "not paid yet" for a pending payment and notifies nobody' do
      order = make_order
      provider_reports("pending")

      dispatch(cb("check_payment_#{order.id}"))

      expect(order.reload.status).to eq(OrderStatus::INVOICE_CREATED)
      expect(api.of(:answer_callback_query).map { |a| a[:text] }).to eq([ "⏳ Оплата ещё не получена. Попробуйте чуть позже." ])
      expect(api.messages_to(barista_id)).to be_empty
    end

    it "shows a friendly toast (not the raw error) when the provider is unreachable" do
      order = make_order
      allow_any_instance_of(MWallet::Client).to receive(:get_status)
        .and_raise(MWalletError::ProviderTimeout.new("Request failed after 3 retries: SID secret"))

      expect { dispatch(cb("check_payment_#{order.id}")) }.not_to raise_error

      answers = api.of(:answer_callback_query)
      expect(answers.size).to eq(1)
      expect(answers.first[:text]).to include("Не удалось проверить оплату")
      expect(api.texts.join).not_to include("SID secret")
    end

    it "tells the user when the order is already closed" do
      order = make_order(status: OrderStatus::EXPIRED)
      provider_reports("pending")

      dispatch(cb("check_payment_#{order.id}"))

      answer = api.of(:answer_callback_query).first
      expect(answer[:text]).to include(OrderStatus.display_name(OrderStatus::EXPIRED))
      expect(answer[:show_alert]).to be(true)
    end

    it "alerts baristas once and shows a payment-problem alert when the tap finds an underpayment" do
      order = make_order(total: 15_000)
      provider_reports("approved", amount: 10_000)

      dispatch(cb("check_payment_#{order.id}"))

      # The tap won the transition to ERROR: nobody else will ever report this payment
      expect(order.reload.status).to eq(OrderStatus::ERROR)
      problem_alerts = api.messages_to(barista_id).select { |m| m[:text].include?("Проблема с оплатой") }
      expect(problem_alerts.size).to eq(1)
      expect(problem_alerts.first[:text]).to include("заказа ##{order.id}", "150.00 KGS", "100.00 KGS")
      expect(barista_new_order_messages).to be_empty

      answer = api.of(:answer_callback_query).first
      expect(answer[:text]).to include("не принята", "свяжется с вами")
      expect(answer[:show_alert]).to be(true)

      # A repeated tap does not alert the baristas again
      dispatch(cb("check_payment_#{order.id}"))
      expect(api.messages_to(barista_id).size).to eq(1)
    end

    {
      OrderStatus::EXPIRED => "после истечения срока счёта",
      OrderStatus::CANCELLED => "после отмены заказа"
    }.each do |closed_status, reason|
      it "tells the client about the refund when the tap finds a payment for a #{closed_status} order" do
        order = make_order(status: closed_status)
        provider_reports("approved")

        dispatch(cb("check_payment_#{order.id}"))

        expect(order.reload.status).to eq(closed_status)
        expect(order.refund_required?).to be(true)
        expect(barista_new_order_messages).to be_empty
        refund_alert = api.messages_to(barista_id).find { |m| m[:text].include?("Требуется возврат") }
        expect(refund_alert[:text]).to include("Клиент оплатил #{reason}")
        expect(refund_alert[:reply_markup].to_h.to_s).to include("refund_done_#{order.id}")
        # The client keeps a message about the money, and the tap shows the same in an alert
        expect(api.messages_to(client_id).map { |m| m[:text] }.join).to include("деньги вернём")
        answer = api.of(:answer_callback_query).first
        expect(answer[:text]).to include("деньги вернём")
        expect(answer[:show_alert]).to be(true)

        # A repeated tap does not request a second refund
        dispatch(cb("check_payment_#{order.id}"))
        expect(api.messages_to(barista_id).count { |m| m[:text].include?("Требуется возврат") }).to eq(1)
      end
    end

    it "does not reveal someone else's order" do
      order = make_order(user_id: 5555)
      expect_any_instance_of(MWallet::Client).not_to receive(:get_status)

      dispatch(cb("check_payment_#{order.id}"))

      expect(api.of(:answer_callback_query).map { |a| a[:text] }).to eq([ "Заказ не найден" ])
    end
  end

  describe "/cancel" do
    it "does not cancel an INVOICE_CREATED order that turns out to be paid, and runs the paid notifications" do
      order = make_order
      provider_reports("approved")
      expect_any_instance_of(MWallet::Client).not_to receive(:cancel_invoice)

      dispatch(text_msg("/cancel"))

      expect(order.reload.status).to eq(OrderStatus::PAID)
      expect(barista_new_order_messages.size).to eq(1)
      client_texts = api.messages_to(client_id).map { |m| m[:text] }
      expect(client_texts).to include(a_string_including("Заказ ##{order.id} уже оплачен"))
      expect(client_texts).to include(a_string_including("Оплата прошла успешно"))
    end

    it "does not cancel an order whose last-chance sync finds an underpayment, and alerts baristas" do
      order = make_order(total: 15_000)
      provider_reports("approved", amount: 10_000)
      expect_any_instance_of(MWallet::Client).not_to receive(:cancel_invoice)

      dispatch(text_msg("/cancel"))

      expect(order.reload.status).to eq(OrderStatus::ERROR)
      problem_alerts = api.messages_to(barista_id).select { |m| m[:text].include?("Проблема с оплатой") }
      expect(problem_alerts.size).to eq(1)
      expect(barista_new_order_messages).to be_empty
      reply = api.messages_to(client_id).first[:text]
      expect(reply).to include("Оплата по заказу ##{order.id} не принята", "свяжется с вами")
      expect(reply).not_to include("/order")
    end

    it 'reports "already paid", not "cancelled", when the order is paid while the cancel is in flight' do
      order = make_order
      provider_reports("pending")
      allow_any_instance_of(MWallet::Client).to receive(:cancel_invoice) do
        # The MWallet callback marks the order paid while invoiceCancel is running
        order.update_column(:status, OrderStatus::PAID)
        {}
      end

      dispatch(text_msg("/cancel"))

      expect(order.reload.status).to eq(OrderStatus::PAID)
      reply = api.messages_to(client_id).last[:text]
      expect(reply).to include("Заказ ##{order.id} уже оплачен")
      expect(reply).not_to include("отменён")
    end

    it "keeps an unconfirmed local cancel discoverable: a later payment is recorded as a refund" do
      order = make_order
      provider_reports("pending")
      allow_any_instance_of(MWallet::Client).to receive(:cancel_invoice)
        .and_raise(MWalletError::NetworkError.new("boom"))

      dispatch(text_msg("/cancel"))
      expect(order.reload.status).to eq(OrderStatus::CANCELLED)

      # The client pays the still open invoice anyway and the callback is lost:
      # the late-payment poll finds it
      provider_reports("approved")
      result = OrderService.sync_payment_status(order)

      expect(result).to include(refund_required: true, previous_status: OrderStatus::CANCELLED)
      expect(order.reload.status).to eq(OrderStatus::CANCELLED)
      expect(order.refund_required?).to be(true)
    end

    it "does not notify anybody when the order had already been marked paid meanwhile" do
      order = make_order
      allow(OrderService).to receive(:sync_payment_status) do |o|
        # e.g. polling marked it paid between listing active orders and the sync
        o.update_column(:status, OrderStatus::PAID)
        { updated: false, order_id: o.id, notify_barista: false }
      end

      dispatch(text_msg("/cancel"))

      expect(order.reload.status).to eq(OrderStatus::PAID)
      expect(api.messages_to(barista_id)).to be_empty
      expect(api.messages_to(client_id).last[:text]).to include("уже оплачен")
    end

    it "cancels an unpaid invoice at the provider and locally" do
      order = make_order
      provider_reports("pending")
      expect_any_instance_of(MWallet::Client).to receive(:cancel_invoice).with("INV-1").and_return(cancel_confirmed)

      dispatch(text_msg("/cancel"))

      expect(order.reload.status).to eq(OrderStatus::CANCELLED)
      reply = api.messages_to(client_id).last[:text]
      expect(reply).to include("Заказ ##{order.id} отменён.")
      expect(reply).to include("/order")
    end

    it "still cancels when the last-chance status check fails" do
      order = make_order
      allow_any_instance_of(MWallet::Client).to receive(:get_status)
        .and_raise(MWalletError::ProviderTimeout.new("timeout"))
      allow_any_instance_of(MWallet::Client).to receive(:cancel_invoice).and_return(cancel_confirmed)

      dispatch(text_msg("/cancel"))

      expect(order.reload.status).to eq(OrderStatus::CANCELLED)
    end

    it "cancels locally and warns not to pay when the provider cancel fails" do
      order = make_order
      provider_reports("pending")
      allow_any_instance_of(MWallet::Client).to receive(:cancel_invoice)
        .and_raise(MWalletError::NetworkError.new("boom"))

      dispatch(text_msg("/cancel"))

      expect(order.reload.status).to eq(OrderStatus::CANCELLED)
      expect(api.messages_to(client_id).last[:text]).to include("не оплачивайте")
    end

    it "cancels only the unpaid order when the client also has a paid one" do
      paid = make_order(status: OrderStatus::PAID, invoice: "INV-PAID")
      unpaid = make_order(invoice: "INV-UNPAID")
      provider_reports("pending")
      allow_any_instance_of(MWallet::Client).to receive(:cancel_invoice).and_return(cancel_confirmed)

      dispatch(text_msg("/cancel"))

      expect(paid.reload.status).to eq(OrderStatus::PAID)
      expect(unpaid.reload.status).to eq(OrderStatus::CANCELLED)
      reply = api.messages_to(client_id).last[:text]
      expect(reply).to include("Заказ ##{paid.id} уже оплачен")
      expect(reply).to include("Заказ ##{unpaid.id} отменён")
    end

    it "explains that an order in preparation is cancelled through the barista" do
      order = make_order(status: OrderStatus::IN_PROGRESS)
      order.update!(assigned_to_barista_id: barista_id)

      dispatch(text_msg("/cancel"))

      expect(order.reload.status).to eq(OrderStatus::IN_PROGRESS)
      expect(api.messages_to(client_id).last[:text]).to include("обратитесь к баристе")
    end

    it "with no active orders just clears the cart" do
      Draft.get_or_create(client_id)

      dispatch(text_msg("/cancel"))

      expect(Draft.for_user(client_id)).to be_nil
      expect(api.messages_to(client_id).last[:text]).to include("Нет активных заказов")
    end
  end

  describe "refund_done_<id>" do
    def late_paid_order(status: OrderStatus::EXPIRED)
      order = make_order(status: status)
      order.record_late_payment!(paid_amount: 15_000)
      order
    end

    it "lets a barista close the refund and tells the client" do
      order = late_paid_order

      dispatch(cb("refund_done_#{order.id}", from: barista_id))

      expect(Payment.find_by(order_id: order.id).status).to eq(PaymentStatus::REFUNDED_FULL)
      expect(order.reload.refund_required?).to be(false)
      expect(api.of(:edit_message_text).last[:text]).to include("Возврат по заказу ##{order.id}")
      expect(api.messages_to(client_id).map { |m| m[:text] }).to include("💸 Деньги за заказ ##{order.id} возвращены.")
    end

    it "records who returned the late payment" do
      order = late_paid_order

      dispatch(cb("refund_done_#{order.id}", from: barista_id))

      operation = PaymentOperation.find_by(order_id: order.id)
      expect(operation).to have_attributes(operation_type: "REFUND", status: "COMPLETED", amount: 15_000)
      expect(operation.reason).to include(barista_id.to_s)
      expect(order.reload.payment.total_refunded).to eq(15_000)
    end

    it "does nothing on a second tap" do
      order = late_paid_order
      dispatch(cb("refund_done_#{order.id}", from: barista_id))
      dispatch(cb("refund_done_#{order.id}", from: barista_id))

      expect(api.messages_to(client_id).size).to eq(1)
      expect(api.of(:answer_callback_query).last[:text]).to include("уже отмечен")
    end

    it "is denied for non-baristas" do
      order = late_paid_order

      dispatch(cb("refund_done_#{order.id}", from: stranger_id))
      dispatch(cb("refund_done_#{order.id}", from: client_id))

      expect(Payment.find_by(order_id: order.id).status).to eq(PaymentStatus::REFUND_REQUIRED)
      expect(api.messages_to(client_id)).to be_empty
    end
  end
end
