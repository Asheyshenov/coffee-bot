# frozen_string_literal: true

require "rails_helper"

RSpec.describe BotRegistration do
  let(:token) { "7000000001:AAHk_secret-Token_value0123456789" }
  let(:me) { Telegram::Bot::Types::User.new(id: 7_000_000_001, is_bot: true, first_name: "Shop", username: "new_shop_bot") }
  let(:previous_bot) { current_tenant.bot }

  def telegram_error(code, description)
    response = Struct.new(:status, :body, :env).new(code, { ok: false, error_code: code, description: description }.to_json, nil)
    Telegram::Bot::Exceptions::ResponseError.new(response: response)
  end

  def register(with_token = token) = described_class.new(tenant: current_tenant, token: with_token).call

  before do
    previous_bot
    allow(api).to receive(:get_me).and_return(me)
  end

  it "connects the bot: stores it, sets the webhook with the secret and the command menu" do
    bot = register

    expect(Telegram::Bot::Client).to have_received(:new).with(token)
    expect(bot).to be_persisted
    expect(bot).to have_attributes(tenant: current_tenant, telegram_bot_id: me.id, username: "new_shop_bot", active: true)
    expect(bot.reload.token).to eq(token)
    expect(current_tenant.bot).to eq(bot)

    webhook = api.of(:set_webhook).sole
    expect(webhook).to eq(url: "#{Rails.configuration.x.public_base_url}/tg/#{bot.id}", secret_token: bot.webhook_secret,
                          allowed_updates: %w[message callback_query], drop_pending_updates: true)
    commands = api.of(:set_my_commands).sole[:commands].map { |c| c[:command] }
    expect(commands).to eq(%w[start order my_orders cancel help])
  end

  it "deactivates the previous bot of the coffee shop and removes its webhook" do
    bot = register

    expect(previous_bot.reload.active).to be(false)
    expect(Bot.where(tenant: current_tenant, active: true)).to eq([ bot ])
    expect(api.of(:delete_webhook).size).to eq(1)
  end

  it "updates the token of a bot that is already connected to this coffee shop" do
    first = register
    new_token = "7000000001:AAHk_rotated-Token_value987654321"

    second = register(new_token)

    expect(second.id).to eq(first.id)
    expect(second.webhook_secret).to eq(first.webhook_secret)
    expect(second.reload.token).to eq(new_token)
    expect(Bot.where(telegram_bot_id: me.id).count).to eq(1)
  end

  it "rejects a malformed token without asking Telegram" do
    expect { register("not a token") }.to raise_error(BotRegistration::InvalidToken)
    expect(api.calls).to be_empty
  end

  it "rejects a token Telegram does not know and changes nothing" do
    allow(api).to receive(:get_me).and_raise(telegram_error(401, "Unauthorized"))

    expect { register }.to raise_error(BotRegistration::InvalidToken) { |e| expect(e.message).not_to include(token) }
    expect(previous_bot.reload.active).to be(true)
    expect(Bot.where(tenant: current_tenant)).to eq([ previous_bot ])
    expect(Bot.find_by(telegram_bot_id: me.id)).to be_nil
  end

  it "rejects a bot that is already connected to another coffee shop" do
    other = create_tenant(slug: "owner-shop")
    ActsAsTenant.without_tenant { Bot.create!(tenant: other, telegram_bot_id: me.id, username: "new_shop_bot", token: token) }

    expect { register }.to raise_error(BotRegistration::AlreadyConnected)
    expect(previous_bot.reload.active).to be(true)
    expect(api.of(:set_webhook)).to be_empty
  end

  it "saves nothing when Telegram refuses the webhook" do
    allow(api).to receive(:set_webhook).and_raise(telegram_error(400, "Bad Request: bad webhook: HTTPS url must be provided"))

    expect { register }.to raise_error(BotRegistration::TelegramError, /HTTPS url must be provided/)
    expect(Bot.find_by(telegram_bot_id: me.id)).to be_nil
    expect(previous_bot.reload.active).to be(true)
  end

  it "reports an unreachable Telegram as a TelegramError" do
    allow(api).to receive(:get_me).and_raise(Faraday::ConnectionFailed, "connection refused")

    expect { register }.to raise_error(BotRegistration::TelegramError)
  end

  it "still connects the bot when the command menu cannot be set" do
    allow(api).to receive(:set_my_commands).and_raise(telegram_error(429, "Too Many Requests"))

    expect(register).to be_active
  end
end
