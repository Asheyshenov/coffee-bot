# frozen_string_literal: true

require "rails_helper"

RSpec.describe "ShopBot::Router across coffee shops" do
  let(:shop_a) { current_tenant }
  let(:shop_b) { create_tenant(slug: "shop-b", name: "Shop B", barista_ids: [ 4004 ]) }

  def in_shop(shop, &) = ActsAsTenant.with_tenant(shop, &)
  def router_of(shop) = ShopBot::Router.new(shop.bot)
  def handle(shop, update) = in_shop(shop) { router_of(shop).handle(update) }

  it "staff of shop A cannot claim shop B's orders" do
    order_b = in_shop(shop_b) { make_order(status: OrderStatus::PAID) }

    handle(shop_a, cb("barista_claim_#{order_b.id}", from: barista_id))

    in_shop(shop_b) { expect(order_b.reload).to have_attributes(status: OrderStatus::PAID, assigned_to_barista_id: nil) }
    expect(api.of(:answer_callback_query).last[:text]).to include("Не удалось принять заказ")
  end

  it "staff of shop B is not a barista in shop A" do
    order_a = make_order(status: OrderStatus::PAID)

    handle(shop_a, cb("barista_claim_#{order_a.id}", from: 4004))
    handle(shop_a, cb("barista_queue", from: 4004))

    expect(order_a.reload.status).to eq(OrderStatus::PAID)
    expect(api.of(:answer_callback_query).map { |a| a[:text] }).to all(eq(ShopBot::Router::BARISTA_ACCESS_DENIED))
  end

  it "a barista of shop B sees only shop B's queue" do
    make_order(status: OrderStatus::PAID)
    order_b = in_shop(shop_b) { make_order(status: OrderStatus::PAID, user_id: 5555) }

    handle(shop_b, cb("barista_queue", from: 4004))

    queue = api.messages_to(4004).map { |m| m[:text] }
    expect(queue.size).to eq(1)
    expect(queue.first).to include("Заказ ##{order_b.id}")
  end

  it "the same Telegram user has separate carts in two shops" do
    croissant_a = MenuItem.create!(category: "Десерты", name: "Круассан", price: 12_000)
    muffin_b = in_shop(shop_b) { MenuItem.create!(category: "Десерты", name: "Маффин", price: 10_000) }

    handle(shop_a, cb("qty_#{croissant_a.id}_2"))
    handle(shop_b, cb("qty_#{muffin_b.id}_1"))
    # A menu item of shop A cannot be put into the cart in shop B
    handle(shop_b, cb("qty_#{croissant_a.id}_1"))

    expect(Draft.for_user(client_id).items.map { |i| [ i["name"], i["qty"] ] }).to eq([ [ "Круассан", 2 ] ])
    in_shop(shop_b) do
      expect(Draft.for_user(client_id).items.map { |i| [ i["name"], i["qty"] ] }).to eq([ [ "Маффин", 1 ] ])
    end

    handle(shop_b, cb("cart_clear"))
    expect(Draft.for_user(client_id).items.size).to eq(1)
  end

  it "the same Telegram user is a separate customer with separate orders in each shop" do
    order_b = in_shop(shop_b) { make_order(status: OrderStatus::READY) }

    handle(shop_a, text_msg("/my_orders"))
    handle(shop_a, cb("check_payment_#{order_b.id}"))

    expect(api.messages_to(client_id).last[:text]).to eq("У вас пока нет заказов.")
    expect(api.of(:answer_callback_query).last[:text]).to eq("Заказ не найден")
  end
end
