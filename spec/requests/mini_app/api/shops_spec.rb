# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Mini App API: GET /app/:bot_id/api/shop", type: :request do
  include_context "shop menu"

  it "returns the shop and its available menu in menu order" do
    current_tenant.update!(name: "Coffee Bot", order_expire_minutes: 20)
    cappuccino = MenuItem.create!(category: "☕ Кофе", name: "Капучино", price: 16_000, position: -1,
                                  description: "Двойной эспрессо", sizes: { "large" => 20_000, "small" => 14_000 },
                                  default_size: "large")

    mini_app_get("shop")

    expect(response).to have_http_status(:ok)
    expect(json_body["shop"]).to eq("name" => "Coffee Bot", "currency" => "KGS", "order_expire_minutes" => 20)
    expect(json_body["categories"]).to eq([ { "name" => "☕ Кофе", "key" => "кофе" },
                                            { "name" => "🍰 Десерты", "key" => "десерты" } ])
    expect(json_body["items"]).to eq([
      { "id" => cappuccino.id, "category" => "☕ Кофе", "name" => "Капучино", "description" => "Двойной эспрессо",
        "price" => 20_000, "default_size" => "large",
        "sizes" => [ { "size" => "small", "label" => "S", "price" => 14_000 },
                     { "size" => "large", "label" => "L", "price" => 20_000 } ] },
      { "id" => latte.id, "category" => "☕ Кофе", "name" => "Латте", "description" => nil,
        "price" => 15_000, "default_size" => "medium",
        "sizes" => [ { "size" => "small", "label" => "S", "price" => 13_000 },
                     { "size" => "medium", "label" => "M", "price" => 15_000 },
                     { "size" => "large", "label" => "L", "price" => 19_000 } ] },
      { "id" => croissant.id, "category" => "🍰 Десерты", "name" => "Круассан", "description" => nil,
        "price" => 12_000, "default_size" => nil, "sizes" => [] }
    ])
  end

  it "leaves out unavailable items and categories without available items" do
    croissant.update!(available: false)
    MenuItem.create!(category: "🍵 Чай", name: "Пуэр", price: 9000, available: false)

    mini_app_get("shop")

    expect(json_body["items"].pluck("name")).to eq([ "Латте" ])
    expect(json_body["categories"].pluck("name")).to eq([ "☕ Кофе" ])
  end

  it "gives a sized item without a valid default size its first size" do
    latte.update!(default_size: nil)

    mini_app_get("shop")

    expect(json_body["items"].find { |i| i["id"] == latte.id }).to include("default_size" => "small", "price" => 13_000)
  end

  it "returns an empty menu" do
    MenuItem.delete_all

    mini_app_get("shop")

    expect(response).to have_http_status(:ok)
    expect(json_body).to include("categories" => [], "items" => [])
  end
end
