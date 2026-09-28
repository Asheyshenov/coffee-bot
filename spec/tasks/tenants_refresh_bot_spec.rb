# frozen_string_literal: true

require "rails_helper"

RSpec.describe "tenants:refresh_bot", type: :task do
  let(:shop) { ActsAsTenant.without_tenant { Tenant.create!(slug: "corner", name: "Corner Coffee") } }
  let(:bot_token) { "777000111:AAH-secret-bot-token" }
  let!(:bot) do
    ActsAsTenant.without_tenant { Bot.create!(tenant: shop, token: bot_token, username: "corner_bot", telegram_bot_id: 777) }
  end

  def refresh(slug = "corner") = without_current_tenant { run_task("tenants:refresh_bot", slug) }

  def telegram_error(code, description)
    response = Struct.new(:status, :body, :env).new(code, { ok: false, error_code: code, description: description }.to_json, nil)
    Telegram::Bot::Exceptions::ResponseError.new(response: response)
  end

  before { stub_public_base_url("https://coffee.example.kg") }

  it "sets the webhook, command menu and Mini App menu button of the connected bot again, with its stored token" do
    result = refresh

    expect(result).to be_success
    expect(result.stdout).to include("corner: bot @corner_bot refreshed, webhook https://coffee.example.kg/tg/#{bot.id}",
                                     "corner: command menu set",
                                     "corner: Mini App menu button set, https://coffee.example.kg/app/#{bot.id}")
    expect(result.output).not_to include(bot_token)
    expect(Telegram::Bot::Client).to have_received(:new).with(bot_token)
    expect(api.of(:set_webhook).sole).to include(url: "https://coffee.example.kg/tg/#{bot.id}", drop_pending_updates: false)
    expect(api.of(:set_chat_menu_button).sole)
      .to eq(menu_button: { type: "web_app", text: "☕ Меню", web_app: { url: "https://coffee.example.kg/app/#{bot.id}" } })
    expect(bot.reload).to have_attributes(active: true, token: bot_token)
  end

  it "explains a skipped menu button (http) and a command menu Telegram refused" do
    stub_public_base_url("http://localhost:3000")
    allow(api).to receive(:set_my_commands).and_raise(telegram_error(429, "Too Many Requests"))

    result = refresh

    expect(result).to be_success
    expect(result.stdout).to include("command menu NOT set", "Mini App menu button skipped: PUBLIC_BASE_URL must be https://")
    expect(api.of(:set_chat_menu_button)).to be_empty
  end

  it "fails when Telegram refuses the webhook, without printing the token" do
    allow(api).to receive(:set_webhook).and_raise(telegram_error(401, "Unauthorized"))

    result = refresh

    expect(result.exit_status).to eq(1)
    expect(result.stderr).to include("bot not refreshed: setWebhook failed (401)")
    expect(result.output).not_to include(bot_token)
  end

  it "filters the token out of unexpected errors" do
    allow(api).to receive(:set_webhook).and_raise(StandardError, "boom #{bot_token}")

    result = refresh

    expect(result.exit_status).to eq(1)
    expect(result.stderr).to include("bot not refreshed", "[FILTERED]")
    expect(result.output).not_to include(bot_token)
  end

  it "fails for a shop without a connected bot or an unknown shop" do
    bot.update!(active: false)

    expect(refresh.stderr).to include("no bot connected", "tenants:connect_bot[corner,TOKEN]")
    expect(refresh("nope").stderr).to match(/"nope" not found/)
    expect(api.calls).to be_empty
  end
end
