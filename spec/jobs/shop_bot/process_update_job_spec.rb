# frozen_string_literal: true

require "rails_helper"

RSpec.describe ShopBot::ProcessUpdateJob do
  let!(:tenant) { current_tenant }
  let!(:bot) { tenant.bot }

  def message_update(text, from: client_id)
    { "update_id" => 11,
      "message" => { "message_id" => 5, "date" => 0, "text" => text, "chat" => { "id" => from, "type" => "private" },
                     "from" => { "id" => from, "is_bot" => false, "first_name" => "U#{from}" } } }
  end

  def callback_update(data, from: client_id)
    { "update_id" => 12,
      "callback_query" => { "id" => "cbq", "chat_instance" => "x", "data" => data,
                            "from" => { "id" => from, "is_bot" => false, "first_name" => "U#{from}" },
                            "message" => { "message_id" => 77, "date" => 0, "chat" => { "id" => from, "type" => "private" } } } }
  end

  def telegram_error(code)
    response = Struct.new(:status, :body, :env).new(code, { ok: false, error_code: code, description: "Too Many Requests" }.to_json, nil)
    Telegram::Bot::Exceptions::ResponseError.new(response: response)
  end

  it "hands the parsed update to the router of the job's bot, inside the bot's coffee shop" do
    seen = nil
    allow(ShopBot::Router).to receive(:new).and_wrap_original do |original, router_bot|
      original.call(router_bot).tap do |router|
        allow(router).to receive(:handle) { |update| seen = [ router_bot, ActsAsTenant.current_tenant, update ] }
      end
    end
    ActsAsTenant.current_tenant = nil

    described_class.perform_now(tenant.id, bot.id, message_update("/start"))

    expect(seen[0]).to eq(bot)
    expect(seen[1]).to eq(tenant)
    expect(seen[2]).to be_a(Telegram::Bot::Types::Message).and(have_attributes(text: "/start"))
  end

  it "handles messages and callback queries" do
    described_class.perform_now(tenant.id, bot.id, message_update("/help"))
    described_class.perform_now(tenant.id, bot.id, callback_update("menu_main"))

    expect(api.messages_to(client_id).last[:text]).to include("Справка")
    expect(api.of(:edit_message_text).last[:text]).to eq("🏠 Главное меню:")
    expect(api.of(:answer_callback_query)).to eq([ { callback_query_id: "cbq" } ])
  end

  it "ignores other update types" do
    described_class.perform_now(tenant.id, bot.id, { "update_id" => 13, "poll_answer" => { "poll_id" => "p", "option_ids" => [] } })

    expect(api.calls).to be_empty
  end

  it "never runs a bot inside another coffee shop" do
    other = create_tenant(slug: "other-job-shop")
    expect(ShopBot::Router).not_to receive(:new)

    described_class.perform_now(tenant.id, other.bot.id, message_update("/start"))
  end

  it "skips a disconnected bot" do
    bot.update!(active: false)
    expect(ShopBot::Router).not_to receive(:new)

    described_class.perform_now(tenant.id, bot.id, message_update("/start"))
  end

  it "logs a failing update instead of retrying it forever" do
    allow_any_instance_of(ShopBot::Router).to receive(:handle).and_raise(RuntimeError, "boom")
    allow(AppLog).to receive(:error)

    expect { described_class.perform_now(tenant.id, bot.id, message_update("/start")) }.not_to raise_error

    expect(AppLog).to have_received(:error).with("Failed to handle Telegram update", hash_including(update_id: 11, error: "RuntimeError: boom"))
    expect(enqueued_jobs).to be_empty
  end

  it "logs an update Telegram cannot parse" do
    allow(AppLog).to receive(:error)

    described_class.perform_now(tenant.id, bot.id, { "update_id" => 14, "message" => { "text" => "no ids" } })

    expect(AppLog).to have_received(:error).with("Failed to handle Telegram update", hash_including(update_id: 14))
  end

  it "never re-runs a failed update: its side effects (cart, order) must not repeat" do
    update = message_update("/start")
    allow(AppLog).to receive(:error)

    [telegram_error(429), Faraday::ConnectionFailed.new("down")].each do |error|
      allow_any_instance_of(ShopBot::Router).to receive(:handle).and_raise(error)

      expect { described_class.perform_now(tenant.id, bot.id, update) }.not_to have_enqueued_job
    end
    expect(AppLog).to have_received(:error).with("Failed to handle Telegram update", hash_including(update_id: 11)).twice
  end

  it "does not retry other Telegram errors" do
    allow_any_instance_of(ShopBot::Router).to receive(:handle).and_raise(telegram_error(400))

    expect { described_class.perform_now(tenant.id, bot.id, message_update("/start")) }.not_to have_enqueued_job
  end

  it "handles the updates of one user one at a time (Solid Queue concurrency key)" do
    key = ->(update) { described_class.new(tenant.id, bot.id, update).concurrency_key }

    expect(key.call(message_update("/start"))).to eq("ShopBot::ProcessUpdateJob/#{bot.id}:#{client_id}")
    expect(key.call(callback_update("menu_main"))).to eq(key.call(message_update("/start")))
    expect(key.call(message_update("/start", from: stranger_id))).not_to eq(key.call(message_update("/start")))
    expect(described_class.concurrency_limit).to eq(1)
    expect(described_class.concurrency_duration).to eq(2.minutes)
  end
end
