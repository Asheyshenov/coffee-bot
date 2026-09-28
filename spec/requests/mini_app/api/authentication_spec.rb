# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Mini App API: bot, shop and initData checks", type: :request do
  include_context "shop menu"

  let(:bot) { current_tenant.bot }

  it "answers for a valid initData of the bot in the URL, as that shop's customer" do
    mini_app_get("cart", init_data: init_data_for(user: { first_name: "Айбек", last_name: "Токтогулов", username: "aibek" }))

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/json")
    customer = Customer.find_by!(telegram_user_id: client_id)
    expect(customer).to have_attributes(tenant_id: current_tenant.id, first_name: "Айбек", last_name: "Токтогулов",
                                        username: "aibek", language_code: "ru")
  end

  it "refreshes the profile of a returning customer (the chat bot's customer record)" do
    existing = Customer.create!(telegram_user_id: client_id, first_name: "Old")

    mini_app_get("cart", init_data: init_data_for(user: { first_name: "New", username: nil }))

    expect(Customer.where(telegram_user_id: client_id).count).to eq(1)
    expect(existing.reload).to have_attributes(first_name: "New", username: nil)
  end

  describe "404 not_found" do
    it "for an unknown bot" do
      get "/app/0/api/shop", headers: mini_app_headers(init_data_for)

      expect(response).to have_http_status(:not_found)
      expect(json_body).to eq("error" => "not_found")
    end

    it "for a non-numeric bot id" do
      get "/app/abc/api/shop", headers: mini_app_headers(init_data_for)

      expect(response).to have_http_status(:not_found)
      expect(json_body).to eq("error" => "not_found")
    end

    it "for an inactive bot, even with a valid initData" do
      bot.update!(active: false)

      mini_app_get("shop", bot: bot)

      expect(response).to have_http_status(:not_found)
      expect(json_body).to eq("error" => "not_found")
    end
  end

  it "answers 503 shop_unavailable when the coffee shop is not serving" do
    current_tenant.update!(status: "suspended")

    mini_app_get("shop")

    expect(response).to have_http_status(:service_unavailable)
    expect(json_body).to eq("error" => "shop_unavailable")
  end

  describe "401 unauthorized" do
    {
      "without initData" => -> { nil },
      "for an empty initData" => -> { "" },
      "for tampered initData" => -> { tampered_init_data },
      "for an expired auth_date" => -> { expired_init_data },
      "for initData signed with another bot's token" => -> { init_data_for(bot_token: "456:OTHER") },
      "for initData without a user" => -> { init_data_for(user: nil) },
      "for a user without a numeric id" => -> { init_data_for(user: { id: "1001" }) },
      "for garbage" => -> { "%%%" }
    }.each do |description, init_data|
      it description do
        mini_app_get("cart", init_data: instance_exec(&init_data))

        expect(response).to have_http_status(:unauthorized)
        expect(json_body).to eq("error" => "unauthorized")
      end
    end

    it "does not create a customer or a cart" do
      mini_app_post("cart/items", { menu_item_id: croissant.id }, init_data: tampered_init_data)

      expect(response).to have_http_status(:unauthorized)
      expect(Customer.count).to eq(0)
      expect(Draft.count).to eq(0)
    end
  end

  describe "tenant isolation" do
    let!(:shop_b) { other_tenant(slug: "shop-b") }
    let!(:bot_b) { ActsAsTenant.without_tenant { shop_b.bot.tap { |b| b.update!(token: "456:SHOP-B") } } }
    let!(:item_b) { ActsAsTenant.with_tenant(shop_b) { MenuItem.create!(category: "Кофе", name: "Раф Б", price: 20_000) } }

    it "rejects initData signed for shop A's bot on shop B's URL" do
      mini_app_get("cart", bot: bot_b, init_data: init_data_for(bot_token: MiniAppApiHelpers::TEST_BOT_TOKEN))

      expect(response).to have_http_status(:unauthorized)
      expect(json_body).to eq("error" => "unauthorized")
    end

    it "keeps a separate customer and cart per shop for the same Telegram user" do
      draft_with_latte(qty: 2)

      mini_app_get("cart", bot: bot_b, init_data: init_data_for(bot_token: "456:SHOP-B"))

      expect(response).to have_http_status(:ok)
      expect(json_body["items"]).to eq([])
      ActsAsTenant.with_tenant(shop_b) { expect(Customer.sole.telegram_user_id).to eq(client_id) }
      expect(Customer.count).to eq(0) # none created in shop A by the shop B request
    end

    it "serves shop B's menu on shop B's URL, and shop A's item ids do not resolve there" do
      mini_app_get("shop", bot: bot_b, init_data: init_data_for(bot_token: "456:SHOP-B"))
      expect(json_body["items"].pluck("name")).to eq([ "Раф Б" ])
      expect(json_body["shop"]["name"]).to eq(shop_b.name)

      mini_app_post("cart/items", { menu_item_id: latte.id, size: "medium" }, bot: bot_b,
                                                                           init_data: init_data_for(bot_token: "456:SHOP-B"))
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to eq("error" => "item_unavailable")
    end

    it "does not show shop B's item in shop A's cart" do
      mini_app_post("cart/items", { menu_item_id: item_b.id })

      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to eq("error" => "item_unavailable")
    end

    it "restores the previous tenant after a request to another shop" do
      shop_a = current_tenant

      mini_app_get("cart", bot: bot_b, init_data: init_data_for(bot_token: "456:SHOP-B"))

      expect(response).to have_http_status(:ok)
      expect(ActsAsTenant.current_tenant).to eq(shop_a)
    end
  end

  it "answers 400 bad_request for a malformed JSON body" do
    mini_app_post("cart/items", "{not json")

    expect(response).to have_http_status(:bad_request)
    expect(json_body).to eq("error" => "bad_request")
  end

  it "answers 500 internal_error without the exception text" do
    allow(MenuItem).to receive(:available).and_raise(RuntimeError, "secret details")

    mini_app_get("shop")

    expect(response).to have_http_status(:internal_server_error)
    expect(json_body).to eq("error" => "internal_error")
    expect(response.body).not_to include("secret")
  end
end
