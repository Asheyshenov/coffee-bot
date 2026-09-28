# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Returning customers and carts" do
  let(:telegram_user) { Telegram::Bot::Types::User.new(id: 777, is_bot: false, first_name: "Aida", username: "aida") }

  it "finds the existing customer on the second message and refreshes the profile" do
    first = Customer.from_telegram(telegram_user)
    renamed = Telegram::Bot::Types::User.new(id: 777, is_bot: false, first_name: "Aidana", username: "aida")

    second = Customer.from_telegram(renamed)

    expect(second.id).to eq(first.id)
    expect(second.first_name).to eq("Aidana")
    expect(Customer.where(telegram_user_id: 777).count).to eq(1)
  end

  it "returns the same cart on every call" do
    first = Draft.get_or_create(777)
    first.update_state("comment" => "keep me")

    expect(Draft.get_or_create(777).id).to eq(first.id)
    expect(Draft.get_or_create(777).comment).to eq("keep me")
  end

  it "still refuses a second customer row for the same shop at the database level" do
    Customer.create!(telegram_user_id: 777)

    expect { Customer.create!(telegram_user_id: 777) }.to raise_error(ActiveRecord::RecordNotUnique)
  end
end
