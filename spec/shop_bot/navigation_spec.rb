# frozen_string_literal: true

require "rails_helper"

RSpec.describe "ShopBot::Router: commands, menu and order wizard" do
  include_context "shop bot"
  include_context "shop menu"

  def markup_of(call) = call[:reply_markup].to_h.to_s

  describe "commands" do
    it "/start greets with the shop name, registers the customer, keeps the cart and shows the reply keyboard" do
      cart.add_item(croissant, 1)

      dispatch(text_msg("/start"))

      messages = api.messages_to(client_id)
      expect(messages.map { |m| m[:text] }.join("\n")).to include("Привет, U#{client_id}", current_tenant.name)
      expect(messages.map { |m| markup_of(m) }.join).to include(ShopBot::Router::PREORDER_BUTTON)
      expect(Customer.find_by(telegram_user_id: client_id).first_name).to eq("U#{client_id}")
      # The cart is shared with the Mini App: /start keeps it and only restarts the wizard
      expect(Draft.for_user(client_id).items.map { |i| i["name"] }).to eq([ "Круассан" ])
      expect(Draft.for_user(client_id).current_step).to eq("select_category")
    end

    it "/start offers the Mini App: a web_app button in the welcome, the reply keyboard stays" do
      stub_public_base_url("https://coffee.example.kg")
      bot = current_tenant.bot

      dispatch(text_msg("/start"))

      greeting, welcome = api.messages_to(client_id)
      expect(greeting[:text]).to include("Привет, U#{client_id}")
      expect(markup_of(greeting)).to include(ShopBot::Router::PREORDER_BUTTON, ShopBot::Router::MY_ORDERS_BUTTON)
      expect(welcome[:text]).to include("Добро пожаловать в #{current_tenant.name}", "Откройте меню")
      expect(welcome[:reply_markup].to_h)
        .to eq(inline_keyboard: [ [ { text: "☕ Открыть меню", web_app: { url: "https://coffee.example.kg/app/#{bot.id}" } } ] ])
      expect(bot.mini_app_url).to eq("https://coffee.example.kg/app/#{bot.id}")
    end

    it "/start without HTTPS has no Mini App button (Telegram would reject it): one welcome as before" do
      stub_public_base_url("http://localhost:3000")

      dispatch(text_msg("/start"))

      message = api.messages_to(client_id).sole
      expect(message[:text]).to include("Привет, U#{client_id}", "Добро пожаловать в #{current_tenant.name}", "Выберите действие")
      expect(markup_of(message)).to include(ShopBot::Router::PREORDER_BUTTON)
      expect(markup_of(message)).not_to include("web_app")
    end

    it "the chat ordering flow still works after the Mini App welcome" do
      stub_public_base_url("https://coffee.example.kg")
      dispatch(text_msg("/start"))

      dispatch(text_msg(ShopBot::Router::PREORDER_BUTTON))

      expect(api.messages_to(client_id).last[:text]).to include("Выберите категорию")
    end

    it "understands /start with a deep-link payload and commands addressed to the bot" do
      dispatch(text_msg("/start staff_invite"))
      dispatch(text_msg("/help@#{current_tenant.bot.username}"))

      texts = api.messages_to(client_id).map { |m| m[:text] }
      expect(texts).to include(a_string_including("Добро пожаловать"))
      expect(texts.last).to include("Справка по командам")
    end

    it "/order shows the categories" do
      dispatch(text_msg("/order"))

      message = api.messages_to(client_id).last
      expect(message[:text]).to include("Выберите категорию")
      expect(markup_of(message)).to include("category_☕ Кофе", "category_🍰 Десерты")
      expect(Draft.for_user(client_id).current_step).to eq("select_category")
    end

    it "the reply keyboard button starts an order too" do
      dispatch(text_msg(ShopBot::Router::PREORDER_BUTTON))

      expect(api.messages_to(client_id).last[:text]).to include("Выберите категорию")
    end

    it "/order with an active order offers a pre-order" do
      order = make_order(status: OrderStatus::PAID)

      dispatch(text_msg("/order"))

      message = api.messages_to(client_id).last
      expect(message[:text]).to include("активные заказы", "##{order.id} (Латте x1)")
      expect(markup_of(message)).to include("preorder_start")
    end

    it "preorder_start opens the main menu" do
      dispatch(cb("preorder_start"))

      expect(api.of(:edit_message_text).last[:text]).to include("Предзаказ")
      expect(markup_of(api.of(:edit_message_text).last)).to include("menu_coffee")
    end

    it "/order on an empty menu says so" do
      MenuItem.delete_all

      dispatch(text_msg("/order"))

      expect(api.messages_to(client_id).last[:text]).to eq("Меню пока пустое.")
    end

    it "/my_orders lists the latest orders" do
      order = make_order(status: OrderStatus::READY)

      dispatch(text_msg("/my_orders"))

      expect(api.messages_to(client_id).last[:text]).to include("##{order.id} - Готов - 150 KGS")
    end

    it "/my_orders without orders" do
      dispatch(text_msg(ShopBot::Router::MY_ORDERS_BUTTON))

      expect(api.messages_to(client_id).last[:text]).to eq("У вас пока нет заказов.")
    end

    it "/help shows the barista commands to baristas only" do
      dispatch(text_msg("/help"))
      dispatch(text_msg("/help", from: barista_id))

      expect(api.messages_to(client_id).last[:text]).not_to include("/barista")
      expect(api.messages_to(barista_id).last[:text]).to include("/barista")
    end
  end

  describe "order wizard" do
    it "category -> item -> quantity -> cart" do
      dispatch(cb("category_🍰 Десерты"))
      expect(markup_of(api.of(:edit_message_text).last)).to include("item_#{croissant.id}")

      dispatch(cb("item_#{croissant.id}"))
      expect(markup_of(api.of(:edit_message_text).last)).to include("qty_#{croissant.id}_3")

      dispatch(cb("qty_#{croissant.id}_3"))
      edit = api.of(:edit_message_text).last
      expect(edit[:text]).to include("Круассан x3", "Итого: 360 KGS")
      expect(markup_of(edit)).to include("cart_checkout")
      expect(Draft.for_user(client_id).current_step).to eq("cart")
    end

    it "a drink asks for the size first" do
      dispatch(cb("item_#{latte.id}"))
      expect(markup_of(api.of(:edit_message_text).last)).to include("size_#{latte.id}_small", "size_#{latte.id}_large")

      dispatch(cb("size_#{latte.id}_large"))
      expect(api.of(:edit_message_text).last[:text]).to include("Латте (L) — 190 KGS")

      dispatch(cb("qty_#{latte.id}_large_2"))
      expect(api.of(:edit_message_text).last[:text]).to include("Добавлено: Латте (L) x2")
      expect(Draft.for_user(client_id).items.first).to include("size" => "large", "qty" => 2, "line_total" => 38_000)
    end

    it "does not add a switched-off item from an old message" do
      croissant.update!(available: false)

      dispatch(cb("qty_#{croissant.id}_1"))

      expect(Draft.for_user(client_id)&.items || []).to be_empty
      expect(api.messages_to(client_id).last[:text]).to eq("Товар не найден.")
    end

    it "a category without available items says so" do
      croissant.update!(available: false)

      dispatch(cb("category_🍰 Десерты"))

      expect(api.messages_to(client_id).last[:text]).to include("нет доступных товаров")
    end

    it "cart edit removes lines" do
      draft = cart
      draft.add_item(croissant, 1)
      draft.add_item_with_size(latte, "small", 1)

      dispatch(cb("cart_edit"))
      expect(markup_of(api.of(:edit_message_text).last)).to include("cart_remove_0", "cart_remove_1")

      dispatch(cb("cart_remove_0"))
      expect(api.of(:edit_message_text).last[:text]).to include("Удалено: Круассан")
      dispatch(cb("cart_remove_0"))
      expect(api.of(:edit_message_text).last[:text]).to include("Удалено: Латте (S)", "Корзина теперь пуста")
      expect(Draft.for_user(client_id)).to be_empty
    end

    it "cart_clear drops the cart" do
      cart.add_item(croissant, 1)

      dispatch(cb("cart_clear"))

      expect(Draft.for_user(client_id)).to be_nil
    end

    it "checkout of an empty cart gets a toast" do
      dispatch(cb("cart_checkout"))

      expect(api.of(:answer_callback_query).last[:text]).to include("Корзина пуста")
    end
  end

  describe "main menu" do
    it "shows a category" do
      dispatch(cb("menu_coffee"))

      edit = api.of(:edit_message_text).last
      expect(edit[:text]).to include("☕ Кофе")
      expect(markup_of(edit)).to include("Латте — от 130 KGS", "item_#{latte.id}")
    end

    it "shows popular items" do
      dispatch(cb("menu_popular"))

      expect(api.of(:edit_message_text).last[:text]).to include("Популярные товары", "Латте", "Круассан")
    end

    it "shows the cart" do
      cart.add_item(croissant, 2)

      dispatch(cb("menu_cart"))

      edit = api.of(:edit_message_text).last
      expect(edit[:text]).to include("Круассан x2")
      expect(markup_of(edit)).to include("cart_checkout")
    end

    it "shows the latest orders" do
      order = make_order(status: OrderStatus::READY)

      dispatch(cb("menu_orders"))

      expect(api.of(:edit_message_text).last[:text]).to include("##{order.id} — Готов")
    end

    it "add_item without sizes asks for the quantity" do
      dispatch(cb("add_item_#{croissant.id}"))

      expect(markup_of(api.of(:edit_message_text).last)).to include("qty_#{croissant.id}_1")
    end

    it "start_order opens the main menu when there is no active order" do
      dispatch(cb("start_order"))

      expect(api.messages_to(client_id).last[:text]).to eq("🏠 Главное меню:")
    end

    it "add-ons can be toggled" do
      syrup = MenuItem.create!(category: "Добавки", name: "Сироп", price: 2_000)
      cart

      dispatch(cb("addon_#{latte.id}_#{syrup.id}"))
      expect(markup_of(api.of(:edit_message_reply_markup).last)).to include("✓ Сироп")
      expect(Draft.for_user(client_id).state["selected_addons"]).to eq([ syrup.id ])

      dispatch(cb("addons_done_#{latte.id}"))
      expect(api.of(:edit_message_text).last[:text]).to include("Выберите количество")
    end
  end

  describe "upsell" do
    it '"➕ Добавить" adds the item and goes on to the comment' do
      cart.add_item_with_size(latte, "medium", 1)

      dispatch(cb("upsell_add_#{croissant.id}"))

      expect(Draft.for_user(client_id).items.map { |i| i["name"] }).to eq(%w[Латте Круассан])
      expect(Draft.for_user(client_id).current_step).to eq("add_comment")
    end

    it '"Нет спасибо" goes on to the comment' do
      cart.add_item_with_size(latte, "medium", 1)

      dispatch(cb("upsell_skip"))

      expect(Draft.for_user(client_id).items.size).to eq(1)
      expect(Draft.for_user(client_id).current_step).to eq("add_comment")
    end
  end
end
