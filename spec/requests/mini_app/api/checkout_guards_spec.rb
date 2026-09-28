# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Mini App API: checkout guards", type: :request do
  include_context "shop menu"

  before do
    Rails.application.config.x.rate_limit_store.clear
    # A new invoice id per call: invoice ids are unique per payment account
    allow_any_instance_of(MWallet::Client).to receive(:create_invoice) do
      { "data" => { "invoice_id" => "INV-G-#{SecureRandom.hex(4)}", "paylink_url" => "https://pay.example" } }
    end
  end

  it "serializes checkouts of one customer on the customer row lock" do
    draft_with_latte
    expect_any_instance_of(Customer).to receive(:with_lock).and_call_original

    mini_app_post("orders")

    expect(response).to have_http_status(:created)
  end

  it "turns a double tap into one order: the second checkout finds the cart already ordered" do
    draft_with_latte

    mini_app_post("orders")
    mini_app_post("orders")

    expect(response).to have_http_status(:unprocessable_content)
    expect(json_body).to eq("error" => "empty_cart")
    expect(Order.count).to eq(1)
  end

  it "limits checkouts to 5 per minute per customer (each one creates an MWallet invoice)" do
    5.times do
      draft_with_latte
      mini_app_post("orders")
      expect(response).to have_http_status(:created)
    end

    draft_with_latte
    mini_app_post("orders")

    expect(response).to have_http_status(:too_many_requests)
    expect(json_body).to eq("error" => "too_many_requests")
    expect(Order.count).to eq(5)

    # another customer of the same shop is not affected
    draft_with_latte(user_id: stranger_id)
    mini_app_post("orders", init_data: init_data_for(user_id: stranger_id))
    expect(response).to have_http_status(:created)
  end
end
