# frozen_string_literal: true

require "rails_helper"

RSpec.describe "ShopBot::Router: cart and checkout" do
  include_context "shop bot"
  include_context "shop menu"

  describe "order items" do
    it "keep the size, so the barista knows what to make" do
      cart.add_item_with_size(latte, "large", 2)

      order = Order.create_from_draft(cart, customer)

      item = order.order_items.first
      expect(item.item_name).to eq("Латте (L)")
      expect(item.size).to eq("large")
      expect(order.format_for_barista).to include("Латте (L) x2")
    end
  end

  describe "confirmation" do
    it "shows current prices and says which ones changed" do
      draft = cart
      draft.add_item_with_size(latte, "medium", 1)
      draft.set_step("add_comment")
      latte.update!(sizes: { "small" => 13_000, "medium" => 17_000, "large" => 19_000 })

      dispatch(text_msg("без сахара"))

      text = api.of(:send_message).last[:text]
      expect(text).to include("Изменилась цена: Латте (M)", "170 KGS", "без сахара")
    end

    it "drops items that are no longer available" do
      draft = cart
      draft.add_item(croissant, 1)
      draft.add_item_with_size(latte, "small", 1)
      croissant.update!(available: false)

      dispatch(cb("skip_comment"))

      text = api.of(:send_message).last[:text]
      expect(text).to include("Больше нет в наличии: Круассан")
      expect(Draft.for_user(client_id).items.map { |i| i["name"] }).to eq([ "Латте" ])
    end

    it "stores no comment when the client skips it" do
      cart.add_item(croissant, 1)

      dispatch(cb("skip_comment"))

      expect(Draft.for_user(client_id).comment).to be_nil
      expect(api.of(:send_message).last[:reply_markup].to_h.to_s).to include("confirm_yes", "confirm_no")
    end

    it "asks for the comment on checkout and offers to skip it" do
      cart.add_item(croissant, 1)

      dispatch(cb("cart_checkout"))

      expect(Draft.for_user(client_id).current_step).to eq("add_comment")
      expect(api.of(:edit_message_text).last[:reply_markup].to_h.to_s).to include("skip_comment")
    end
  end

  describe '"✅ Да"' do
    before { stub_invoice_creation(invoice_id: "INV-CHK") }

    it "creates the order, clears the cart and sends the payment link" do
      cart.add_item_with_size(latte, "large", 2)

      dispatch(cb("confirm_yes"))

      order = Order.sole
      expect(order).to have_attributes(status: OrderStatus::INVOICE_CREATED, total_amount: 38_000,
                                       invoice_id_provider: "INV-CHK", payment_account: current_tenant.payment_account)
      expect(order.customer.telegram_user_id).to eq(client_id)
      expect(Draft.for_user(client_id)).to be_nil
      expect(api.of(:edit_message_text).last[:text]).to eq("✅ Заказ ##{order.id} создан!")
      payment = api.messages_to(client_id).last
      expect(payment[:text]).to include("Оплата заказа ##{order.id}")
      expect(payment[:reply_markup].to_h.to_s).to include("check_payment_#{order.id}")
    end

    it "asks to confirm again instead of charging a price the client has not seen" do
      cart.add_item(croissant, 1)
      croissant.update!(price: 14_000)

      dispatch(cb("confirm_yes"))

      expect(Order.count).to eq(0)
      expect(api.of(:send_message).last[:text]).to include("Изменилась цена", "Подтвердить заказ?")

      dispatch(cb("confirm_yes"))
      expect(Order.sole.total_amount).to eq(14_000)
    end

    it "shows a neutral message when the invoice cannot be created" do
      cart.add_item(croissant, 1)
      allow_any_instance_of(MWallet::Client).to receive(:create_invoice)
        .and_raise(MWalletError::BusinessError.new("Команда не определена", code: 1))

      dispatch(cb("confirm_yes"))

      expect(api.texts.join).to include("Не удалось создать счёт на оплату")
      expect(api.texts.join).not_to include("Команда не определена")
      expect(Draft.for_user(client_id)).not_to be_nil # the client can retry
    end

    it "still sends the payment link when the confirmation message cannot be edited" do
      cart.add_item(croissant, 1)
      allow(api).to receive(:edit_message_text).and_raise(StandardError, "message to edit not found")

      dispatch(cb("confirm_yes"))

      expect(api.messages_to(client_id).last[:text]).to include("Оплата заказа ##{Order.sole.id}")
      expect(api.texts.join).not_to include("Не удалось создать счёт")
    end

    it '"❌ Нет" drops the cart' do
      cart.add_item(croissant, 1)

      dispatch(cb("confirm_no"))

      expect(Draft.for_user(client_id)).to be_nil
      expect(Order.count).to eq(0)
      expect(api.of(:edit_message_text).last[:text]).to include("Заказ отменён")
    end
  end

  describe "quick reorder" do
    it "repeats sizes and quantities and skips items that are gone" do
      draft = cart
      draft.add_item_with_size(latte, "small", 2)
      draft.add_item(croissant, 1)
      order = Order.create_from_draft(draft, customer)
      Draft.clear(client_id)
      croissant.update!(available: false)

      dispatch(cb("reorder_#{order.id}"))

      items = Draft.for_user(client_id).items
      expect(items.map { |i| [ i["display_name"], i["size"], i["qty"] ] }).to eq([ [ "Латте (S)", "small", 2 ] ])
      expect(api.of(:edit_message_text).last[:text]).to include("Больше нет в наличии: Круассан")
    end

    it "does not repeat someone else's order" do
      draft = Draft.get_or_create(5555)
      draft.add_item(croissant, 1)
      order = Order.create_from_draft(draft, customer(5555))

      dispatch(cb("reorder_#{order.id}"))

      expect(Draft.for_user(client_id)).to be_nil
      expect(api.of(:answer_callback_query).last[:text]).to eq("Заказ не найден")
    end
  end

  describe "menu categories" do
    it "match regardless of emoji in the stored name" do
      MenuItem.create!(category: "🥛 Добавки", name: "Сироп", price: 2_000)

      expect(MenuService.addons.map(&:name)).to eq([ "Сироп" ])
      expect(MenuService.items_by_category("Кофе").map(&:name)).to eq([ "Латте" ])
    end

    it "popular items leave out unavailable ones" do
      croissant.update!(available: false)

      expect(MenuService.popular_items.map(&:name)).not_to include("Круассан")
    end
  end
end
