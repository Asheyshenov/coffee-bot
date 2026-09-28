# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Mini App API: cart", type: :request do
  include_context "shop menu"

  def add(body) = mini_app_post("cart/items", body)
  def cart = Draft.for_user(client_id)

  describe "GET /cart" do
    it "returns an empty cart without creating one" do
      mini_app_get("cart")

      expect(response).to have_http_status(:ok)
      expect(json_body).to eq("items" => [], "total" => 0, "count" => 0, "comment" => nil, "max_qty_per_line" => 20)
      expect(Draft.count).to eq(0)
    end

    it "shows the cart built in the chat bot (the shared Draft)" do
      draft = draft_with_latte(qty: 2)
      draft.add_item(croissant, 1)
      draft.set_comment("без сахара")

      mini_app_get("cart")

      expect(json_body).to eq(
        "items" => [
          { "index" => 0, "menu_item_id" => latte.id, "name" => "Латте", "display_name" => "Латте (M)",
            "size" => "medium", "qty" => 2, "unit_price" => 15_000, "line_total" => 30_000 },
          { "index" => 1, "menu_item_id" => croissant.id, "name" => "Круассан", "display_name" => "Круассан",
            "size" => nil, "qty" => 1, "unit_price" => 12_000, "line_total" => 12_000 }
        ],
        "total" => 42_000, "count" => 3, "comment" => "без сахара", "max_qty_per_line" => 20
      )
    end

    it "is the cart of the initData user only" do
      draft_with_latte(user_id: stranger_id)

      mini_app_get("cart")

      expect(json_body["items"]).to eq([])
    end
  end

  describe "POST /cart/items" do
    it "adds a line to the cart the chat bot sees" do
      add(menu_item_id: latte.id, size: "large", qty: 2)

      expect(response).to have_http_status(:ok)
      expect(json_body["items"]).to eq([ { "index" => 0, "menu_item_id" => latte.id, "name" => "Латте",
                                           "display_name" => "Латте (L)", "size" => "large", "qty" => 2,
                                           "unit_price" => 19_000, "line_total" => 38_000 } ])
      expect(json_body).to include("total" => 38_000, "count" => 2)
      expect(cart.format_cart).to include("Латте (L) x2")
    end

    it "keeps the chat bot's wizard state" do
      Draft.update_state(client_id, "step" => "select_item", "category" => "☕ Кофе")

      add(menu_item_id: croissant.id)

      expect(cart.state).to include("step" => "select_item", "category" => "☕ Кофе")
      expect(cart.items.size).to eq(1)
    end

    it "merges the same item and size with an existing line (also one added in the chat)" do
      draft_with_latte(qty: 1)

      add(menu_item_id: latte.id, size: "medium", qty: 3)

      expect(json_body["items"].size).to eq(1)
      expect(json_body["items"].first).to include("qty" => 4, "line_total" => 60_000)
    end

    it "adds a different size as a separate line" do
      draft_with_latte(qty: 1)

      add(menu_item_id: latte.id, size: "small")

      expect(json_body["items"].pluck("display_name", "qty")).to eq([ [ "Латте (M)", 1 ], [ "Латте (S)", 1 ] ])
    end

    it "defaults qty to 1 and a sized item to its default size" do
      add(menu_item_id: latte.id)

      expect(json_body["items"].first).to include("size" => "medium", "qty" => 1, "unit_price" => 15_000)
    end

    it "adds an item without sizes with size null" do
      add(menu_item_id: croissant.id, size: nil, qty: 1)

      expect(json_body["items"].first).to include("size" => nil, "display_name" => "Круассан")
    end

    it "caps a line at 20, for a new line and when merging" do
      add(menu_item_id: croissant.id, qty: 25)
      expect(json_body["items"].first["qty"]).to eq(20)

      add(menu_item_id: latte.id, qty: 15)
      add(menu_item_id: latte.id, qty: 15)
      expect(json_body["items"].last).to include("qty" => 20, "line_total" => 300_000)
    end

    [ 0, -1, 1.5, "abc", "2.0", [ 1 ], { "n" => 1 }, nil, true ].each do |qty|
      it "answers 422 invalid_qty for qty #{qty.inspect}" do
        add(menu_item_id: croissant.id, qty: qty)

        expect(response).to have_http_status(:unprocessable_content)
        expect(json_body).to eq("error" => "invalid_qty")
        expect(cart).to be_nil
      end
    end

    it "answers 422 item_unavailable for an unavailable item" do
      croissant.update!(available: false)

      add(menu_item_id: croissant.id)

      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to eq("error" => "item_unavailable")
      expect(cart).to be_nil
    end

    [ 0, 999_999_999, 10**20, "abc", nil, 1.0, [ 1 ] ].each do |id|
      it "answers 422 item_unavailable for menu_item_id #{id.inspect}" do
        add(menu_item_id: id)

        expect(response).to have_http_status(:unprocessable_content)
        expect(json_body).to eq("error" => "item_unavailable")
      end
    end

    it "answers 422 item_unavailable without menu_item_id" do
      add(qty: 1)

      expect(json_body).to eq("error" => "item_unavailable")
    end

    [ "xl", "MEDIUM", "", 1, [ "medium" ] ].each do |size|
      it "answers 422 item_unavailable for the unknown size #{size.inspect}" do
        add(menu_item_id: latte.id, size: size)

        expect(response).to have_http_status(:unprocessable_content)
        expect(json_body).to eq("error" => "item_unavailable")
      end
    end

    it "answers 422 item_unavailable for a size the item doesn't have" do
      small_only = MenuItem.create!(category: "☕ Кофе", name: "Ристретто", price: 9000, sizes: { "small" => 9000 })

      add(menu_item_id: small_only.id, size: "large")
      expect(json_body).to eq("error" => "item_unavailable")

      add(menu_item_id: croissant.id, size: "medium")
      expect(json_body).to eq("error" => "item_unavailable")
    end
  end

  describe "PATCH /cart/items/:index" do
    before do
      draft = draft_with_latte(qty: 2)
      draft.add_item(croissant, 1)
    end

    it "sets the quantity" do
      mini_app_patch("cart/items/1", { qty: 5 })

      expect(response).to have_http_status(:ok)
      expect(json_body["items"].last).to include("qty" => 5, "line_total" => 60_000)
      expect(json_body).to include("total" => 90_000, "count" => 7)
      expect(cart.items.last["qty"]).to eq(5)
    end

    it "accepts 20 and removes the line with 0" do
      mini_app_patch("cart/items/0", { qty: 20 })
      expect(json_body["items"].first["qty"]).to eq(20)

      mini_app_patch("cart/items/0", { qty: 0 })
      expect(json_body["items"].pluck("name")).to eq([ "Круассан" ])
      expect(json_body["items"].first["index"]).to eq(0)
    end

    [ -1, 21, 2.5, "x", nil ].each do |qty|
      it "answers 422 invalid_qty for qty #{qty.inspect} and keeps the line" do
        mini_app_patch("cart/items/0", { qty: qty })

        expect(response).to have_http_status(:unprocessable_content)
        expect(json_body).to eq("error" => "invalid_qty")
        expect(cart.items.first["qty"]).to eq(2)
      end
    end

    it "answers 404 not_found for an index that doesn't exist" do
      mini_app_patch("cart/items/2", { qty: 1 })

      expect(response).to have_http_status(:not_found)
      expect(json_body).to eq("error" => "not_found")
    end

    it "answers 404 not_found without a cart" do
      Draft.clear(client_id)

      mini_app_patch("cart/items/0", { qty: 1 })

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE /cart/items/:index" do
    it "removes a line" do
      draft = draft_with_latte(qty: 2)
      draft.add_item(croissant, 1)

      mini_app_delete("cart/items/0")

      expect(response).to have_http_status(:ok)
      expect(json_body["items"].pluck("index", "name")).to eq([ [ 0, "Круассан" ] ])
      expect(cart.items.size).to eq(1)
    end

    it "answers 404 not_found for an index that doesn't exist" do
      draft_with_latte

      mini_app_delete("cart/items/1")

      expect(response).to have_http_status(:not_found)
      expect(json_body).to eq("error" => "not_found")
      expect(cart.items.size).to eq(1)
    end
  end

  describe "DELETE /cart" do
    it "empties the cart, also for the chat bot" do
      draft_with_latte(qty: 2)

      mini_app_delete("cart")

      expect(response).to have_http_status(:ok)
      expect(json_body).to include("items" => [], "total" => 0, "count" => 0)
      expect(Draft.get_state(client_id)["items"]).to eq([])
    end

    it "is fine with no cart" do
      mini_app_delete("cart")

      expect(response).to have_http_status(:ok)
      expect(json_body["items"]).to eq([])
    end
  end
end
