# frozen_string_literal: true

require "rails_helper"

# Edge-case audit of the bot (ported from the legacy edge-case suite).
# Every example asserts the expected behaviour, so a failing example is a bug.
RSpec.describe "Bot edge cases" do
  include_context "shop bot"
  include_context "shop menu"

  def make_order_with_latte(status:, user_id: client_id)
    make_order(status: status, user_id: user_id).tap { |order| order.order_items.first.update!(menu_item: latte) }
  end

  describe "Order lifecycle / cancellation" do
    it "/cancel does not cancel an already PAID order without a refund" do
      order = make_order(status: OrderStatus::PAID)
      dispatch(text_msg("/cancel"))
      expect(order.reload.status).to eq(OrderStatus::PAID)
    end

    it "/cancel does not cancel an order the barista is already preparing" do
      order = make_order(status: OrderStatus::IN_PROGRESS)
      order.update!(assigned_to_barista_id: barista_id)
      dispatch(text_msg("/cancel"))
      expect(order.reload.status).to eq(OrderStatus::IN_PROGRESS)
    end

    it 'double-tap on "✅ Да" creates exactly one order and shows no Ruby error to the user' do
      draft_with_latte
      stub_invoice_creation(invoice_id: "INV-DBL")

      dispatch(cb("confirm_yes"))
      dispatch(cb("confirm_yes", id: "q-second"))

      expect(Order.where(telegram_user_id: client_id).count).to eq(1)
      expect(api.texts.join).not_to match(/undefined method|NoMethodError/)
      second = api.of(:answer_callback_query).find { |a| a[:callback_query_id] == "q-second" }
      expect(second).to include(text: a_string_including("заказ уже оформлен"), show_alert: true)
    end

    it "comment is truncated to the 200-char DB column limit" do
      draft_with_latte.set_step("add_comment")
      dispatch(text_msg("x" * 500))
      expect(Draft.for_user(client_id).comment.length).to be <= 200
    end

    it "sending a sticker/photo during the comment step does not crash and gets a hint" do
      draft_with_latte.set_step("add_comment")

      expect(dispatch_like_job(non_text_msg)).to be_nil

      expect(api.messages_to(client_id).last[:text]).to include("Отправьте комментарий текстом")
      expect(Draft.for_user(client_id).current_step).to eq("add_comment")
    end

    it "rejects checkout if an item became unavailable after it was put in the cart" do
      draft = draft_with_latte
      latte.update!(available: false)
      expect(OrderService.create_from_draft(draft, customer)).to be_nil
    end

    it "uses the CURRENT price at checkout, not the price when added to cart" do
      draft = draft_with_latte
      latte.update!(sizes: { "small" => 13_000, "medium" => 99_000, "large" => 19_000 })
      expect(OrderService.create_from_draft(draft, customer).total_amount).to eq(99_000)
    end

    it "crafted callback qty_<id>_0 must not put a zero-quantity line into the cart" do
      dispatch(cb("qty_#{croissant.id}_0"))
      items = Draft.for_user(client_id)&.items || []
      expect(items.all? { |i| i["qty"].positive? }).to be(true)
      expect(api.of(:answer_callback_query).last).to include(text: ShopBot::Router::INVALID_QTY_TEXT, show_alert: true)
    end

    it "crafted callback with huge quantity is capped" do
      dispatch(cb("qty_#{croissant.id}_99999"))
      dispatch(cb("qty_#{latte.id}_small_99999"))
      expect(Draft.for_user(client_id).items.map { |i| i["qty"] }).to all(be <= Draft::MAX_QTY_PER_LINE)
    end

    it "order items are never silently dropped when one line fails validation" do
      draft = Draft.get_or_create(client_id)
      draft.update_state("items" => [
        { "menu_item_id" => latte.id, "name" => "Латте", "unit_price" => 15_000, "qty" => 1, "line_total" => 15_000 },
        { "menu_item_id" => croissant.id, "name" => "Круассан", "unit_price" => 12_000, "qty" => 0, "line_total" => 0 }
      ])
      order = OrderService.create_from_draft(draft, customer)
      expect(order.order_items.sum(&:line_total)).to eq(order.total_amount)
    end

    it "quick reorder works" do
      order = make_order_with_latte(status: OrderStatus::READY)
      expect(dispatch_like_job(cb("reorder_#{order.id}"))).to be_nil
      expect(Draft.for_user(client_id).items.size).to eq(1)
    end
  end

  describe "Authorization (barista actions)" do
    it "a non-barista cannot view the barista queue (leaks client names)" do
      make_order(status: OrderStatus::PAID, user_id: 5555)
      dispatch(cb("barista_queue", from: stranger_id))
      expect(api.texts.join).not_to include("Заказ #")
    end

    it "a non-barista cannot claim a paid order via a crafted callback" do
      order = make_order(status: OrderStatus::PAID)
      dispatch(cb("barista_claim_#{order.id}", from: stranger_id))
      expect(order.reload.status).to eq(OrderStatus::PAID)
    end

    it 'a client cannot claim and "complete" their own order' do
      order = make_order(status: OrderStatus::PAID)
      dispatch(cb("barista_claim_#{order.id}", from: client_id))
      dispatch(cb("barista_complete_#{order.id}", from: client_id))
      expect(order.reload.status).not_to eq(OrderStatus::READY)
    end

    it "barista cannot complete an order assigned to someone else" do
      order = make_order(status: OrderStatus::IN_PROGRESS)
      order.update!(assigned_to_barista_id: 9999)
      dispatch(cb("barista_complete_#{order.id}", from: barista_id))
      expect(order.reload.status).to eq(OrderStatus::IN_PROGRESS)
    end

    it "two baristas claiming the same order: only one wins" do
      add_barista(2003)
      order = make_order(status: OrderStatus::PAID)
      dispatch(cb("barista_claim_#{order.id}", from: barista_id))
      dispatch(cb("barista_claim_#{order.id}", from: 2003))
      expect(order.reload.assigned_to_barista_id).to eq(barista_id)
    end
  end

  describe "UX / Telegram protocol" do
    it "each callback query is answered at most once (Telegram rejects re-answers => toasts/alerts are lost)" do
      make_order(status: OrderStatus::PAID)
      dispatch_like_job(cb("start_order")) # wants show_alert "already have active order"
      dispatch_like_job(cb("menu_orders"))
      dispatch_like_job(cb("skip_comment"))
      expect(api.calls.map(&:first)).not_to include(:answer_callback_query_rejected)
    end

    it 'the "active order" alert text actually reaches the user' do
      order = make_order(status: OrderStatus::PAID)
      dispatch_like_job(cb("start_order"))
      alerts = api.of(:answer_callback_query).select { |a| a[:text] }
      expect(alerts).to eq([ { callback_query_id: alerts.first[:callback_query_id], text: "У вас уже есть активный заказ ##{order.id}",
                               show_alert: true } ])
    end

    it 'main menu "☕ Кофе" shows items for a menu created by MenuService.seed_menu' do
      MenuItem.delete_all
      MenuService.seed_menu(current_tenant)
      dispatch(cb("menu_coffee"))
      expect(api.of(:edit_message_text).last[:text]).to include("Кофе")
    end

    it 'main menu "➕ Добавки" matches the category name used in the data' do
      MenuItem.create!(category: "🥛 Добавки", name: "Сироп", price: 2000)
      dispatch(cb("menu_addons"))
      expect(api.of(:edit_message_text)).not_to be_empty
    end

    it 'empty-cart text has a real line break, not a literal "\n"' do
      dispatch(cb("menu_cart"))
      expect(api.texts.join).not_to include('\n')
      expect(api.texts.join).to include("Корзина пуста\n")
    end

    it "unexpected errors are not shown verbatim to the user" do
      draft_with_latte
      allow_any_instance_of(MWallet::Client).to receive(:create_invoice)
        .and_raise(MWalletError::BusinessError.new("SID 12345 invalid hash for merchant", code: 42))
      dispatch(cb("confirm_yes"))
      expect(api.texts.join).not_to include("SID 12345")
      expect(api.texts.join).to include(ShopBot::Router::INVOICE_FAILED_TEXT)
    end

    it "unknown text with no draft gets a hint instead of silence" do
      dispatch(text_msg("привет"))
      expect(api.of(:send_message).last[:text]).to eq(ShopBot::Router::UNKNOWN_INPUT_TEXT)
    end

    it "item not in any draft: addon toggle on stale message does not crash" do
      expect(dispatch_like_job(cb("addon_#{latte.id}_#{croissant.id}"))).to be_nil
    end

    it "cart_remove with out-of-range index is a no-op" do
      draft_with_latte
      expect(dispatch_like_job(cb("cart_remove_42"))).to be_nil
      expect(Draft.for_user(client_id).items.size).to eq(1)
    end

    it "callback for a deleted menu item does not crash" do
      expect(dispatch_like_job(cb("item_999999"))).to be_nil
      expect(dispatch_like_job(cb("size_999999_small"))).to be_nil
      expect(dispatch_like_job(cb("qty_999999_small_1"))).to be_nil
    end

    it "an unknown callback is just answered" do
      dispatch(cb("barista_detail_1", id: "q-unknown"))
      expect(api.calls).to eq([ [ :answer_callback_query, { callback_query_id: "q-unknown" } ] ])
    end

    it "a repeated tap that would not change the message is not an error" do
      not_modified = Struct.new(:status, :body, :env).new(400, {
        ok: false, error_code: 400,
        description: "Bad Request: message is not modified: specified new message content and reply markup are exactly the same"
      }.to_json, nil)
      allow(api).to receive(:edit_message_text).and_raise(Telegram::Bot::Exceptions::ResponseError.new(response: not_modified))

      expect(dispatch_like_job(cb("menu_main"))).to be_nil
    end
  end
end
