# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Telegram webhooks", type: :request do
  let(:bot) { current_tenant.bot }

  def tg_from(id) = { id: id, is_bot: false, first_name: "U#{id}" }

  def message_update(text, from: client_id, update_id: 1)
    { update_id: update_id,
      message: { message_id: 10, date: 0, chat: { id: from, type: "private" }, from: tg_from(from), text: text } }
  end

  def callback_update(data, from: client_id, update_id: 2)
    { update_id: update_id,
      callback_query: { id: "cbq-#{update_id}", from: tg_from(from), chat_instance: "x", data: data,
                        message: { message_id: 77, date: 0, chat: { id: from, type: "private" } } } }
  end

  def deliver(update, to: bot, secret: to.webhook_secret)
    headers = { "CONTENT_TYPE" => "application/json" }
    headers[TelegramWebhooksController::SECRET_HEADER] = secret if secret
    post "/tg/#{to.id}", params: update.is_a?(String) ? update : update.to_json, headers: headers
  end

  it "queues the update for the bot's coffee shop and answers 200 right away" do
    expect { deliver(message_update("/start")) }
      .to have_enqueued_job(ShopBot::ProcessUpdateJob)
      .with(current_tenant.id, bot.id, hash_including("update_id" => 1, "message" => hash_including("text" => "/start")))

    expect(response).to have_http_status(:ok)
    expect(api.calls).to be_empty # nothing is done inside the request
  end

  it "drops a redelivered update (same update_id) instead of handling it twice" do
    update = message_update("/start", update_id: 777)

    deliver(update)
    deliver(update)

    expect(response).to have_http_status(:ok)
    expect(ShopBot::ProcessUpdateJob).to have_been_enqueued.once
  end

  it "keeps update ids per bot: the same id from another shop's bot is a different update" do
    other = create_tenant(slug: "other-shop")
    other_bot = ActsAsTenant.without_tenant { other.bot }
    update = message_update("/start", update_id: 778)

    deliver(update)
    deliver(update, to: other_bot)

    expect(ShopBot::ProcessUpdateJob).to have_been_enqueued.twice
  end

  it "handles the queued update with the shop's bot" do
    perform_enqueued_jobs { deliver(message_update("/start")) }

    expect(api.messages_to(client_id).last[:text]).to include("Добро пожаловать в #{current_tenant.name}")
  end

  it "answers 404 for an unknown bot" do
    post "/tg/0", params: message_update("/start").to_json, headers: { "CONTENT_TYPE" => "application/json" }

    expect(response).to have_http_status(:not_found)
    expect(enqueued_jobs).to be_empty
  end

  it "answers 404 for a disconnected bot" do
    bot.update!(active: false)

    deliver(message_update("/start"))

    expect(response).to have_http_status(:not_found)
    expect(enqueued_jobs).to be_empty
  end

  it "answers 401 for a wrong or missing secret token" do
    deliver(message_update("/start"), secret: "wrong")
    expect(response).to have_http_status(:unauthorized)

    deliver(message_update("/start"), secret: nil)
    expect(response).to have_http_status(:unauthorized)

    expect(enqueued_jobs).to be_empty
  end

  it "ignores updates for a suspended coffee shop" do
    current_tenant.update!(status: "suspended")

    deliver(message_update("/start"))

    expect(response).to have_http_status(:ok)
    expect(enqueued_jobs).to be_empty
  end

  it "ignores update types the bot does not handle" do
    deliver({ update_id: 3, edited_message: message_update("hi")[:message] })

    expect(response).to have_http_status(:ok)
    expect(enqueued_jobs).to be_empty
  end

  it "answers 400 for a body that is not an update" do
    deliver("not json")
    expect(response).to have_http_status(:bad_request)

    deliver("[1, 2]")
    expect(response).to have_http_status(:bad_request)
    expect(enqueued_jobs).to be_empty
  end

  describe "isolation between coffee shops" do
    let(:shop_b) { create_tenant(slug: "shop-b", name: "Shop B") }
    let!(:order_b) { ActsAsTenant.with_tenant(shop_b) { make_order(status: OrderStatus::PAID) } }

    it "an update of bot A can never read shop B data" do
      perform_enqueued_jobs do
        deliver(callback_update("check_payment_#{order_b.id}"))
        deliver(callback_update("reorder_#{order_b.id}", update_id: 3))
        deliver(message_update("/my_orders", update_id: 4))
        deliver(callback_update("barista_claim_#{order_b.id}", from: barista_id, update_id: 5))
      end

      answers = api.of(:answer_callback_query).map { |a| a[:text] }
      expect(answers.first(2)).to eq([ "Заказ не найден", "Заказ не найден" ])
      expect(api.messages_to(client_id).last[:text]).to eq("У вас пока нет заказов.")
      expect(api.texts.join).not_to include("##{order_b.id}")
      ActsAsTenant.with_tenant(shop_b) { expect(order_b.reload).to have_attributes(status: OrderStatus::PAID, assigned_to_barista_id: nil) }
    end

    it "the secret of bot A does not open bot B" do
      deliver(message_update("/start"), to: shop_b.bot, secret: bot.webhook_secret)

      expect(response).to have_http_status(:unauthorized)
    end

    it "bot B's updates run in shop B" do
      perform_enqueued_jobs { deliver(message_update("/my_orders"), to: shop_b.bot) }

      expect(api.messages_to(client_id).last[:text]).to include("##{order_b.id}")
    end
  end
end
