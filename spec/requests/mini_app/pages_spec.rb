# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Mini App page", type: :request do
  let(:bot) { current_tenant.bot }
  let(:html) { Nokogiri::HTML(response.body) }

  def app_root = html.at_css("#mini-app")

  def expect_telegram_can_embed_it
    expect(response.headers["X-Frame-Options"]).to be_nil
    expect(response.headers["Content-Security-Policy"])
      .to eq("frame-ancestors https://web.telegram.org https://*.telegram.org")
  end

  it "serves the app shell of an active bot, without initData" do
    get "/app/#{bot.id}"

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/html")
    expect(app_root.to_h).to include("data-page" => "app", "data-bot-id" => bot.id.to_s,
                                     "data-api-base" => "/app/#{bot.id}/api",
                                     "data-shop-name" => current_tenant.name, "data-bot-username" => bot.username)
    expect(html.at_css("title").text).to eq(current_tenant.name)
    expect(html.at_css("html")["lang"]).to eq("ru")
  end

  it "loads telegram-web-app.js before the app module, and only the Mini App modules" do
    get "/app/#{bot.id}"

    scripts = html.css("head script")
    telegram = scripts.index { |s| s["src"] == "https://telegram.org/js/telegram-web-app.js" }
    app = scripts.index { |s| s["type"] == "module" && s.text.include?('import "mini_app/app"') }
    expect(telegram).to be < app

    imports = JSON.parse(html.at_css('script[type="importmap"]').text).fetch("imports")
    expect(imports.keys).to include("mini_app/app", "mini_app/api", "mini_app/telegram", "mini_app/screens/menu",
                                    "mini_app/screens/cart", "mini_app/screens/order")
    preloads = html.css('link[rel="modulepreload"]').map { |link| link["href"] }
    expect(preloads).to include(imports.fetch("mini_app/app"), imports.fetch("mini_app/screens/order"))
    expect(preloads).not_to include(imports.fetch("@hotwired/turbo-rails"), imports.fetch("application"))
    expect(html.at_css('link[rel="stylesheet"]')["href"]).to match(%r{/assets/tailwind-\w+\.css})
  end

  it "lets Telegram Desktop and Web embed the page" do
    get "/app/#{bot.id}"

    expect_telegram_can_embed_it
  end

  it "answers 404 for an unknown or inactive bot" do
    get "/app/0"
    expect(response).to have_http_status(:not_found)
    expect(response.body).to include("Меню не найдено")
    expect(html.at_css("#mini-app")["data-page"]).to eq("notice")
    expect_telegram_can_embed_it

    get "/app/not-a-number"
    expect(response).to have_http_status(:not_found)

    bot.update!(active: false)
    get "/app/#{bot.id}"
    expect(response).to have_http_status(:not_found)
    expect(response.body).not_to include("data-api-base")
  end

  it "shows a friendly page when the coffee shop is suspended" do
    current_tenant.update!(status: "suspended")

    get "/app/#{bot.id}"

    expect(response).to have_http_status(:service_unavailable)
    expect(html.at_css("h1").text).to eq("#{current_tenant.name} временно не принимает заказы")
    expect(response.body).not_to include("data-api-base")
    expect_telegram_can_embed_it
  end

  it "serves a trial coffee shop" do
    current_tenant.update!(status: "trial")

    get "/app/#{bot.id}"

    expect(response).to have_http_status(:ok)
  end

  it "is the same HTML page whatever format the URL asks for" do
    get "/app/#{bot.id}.json"

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/html")
  end

  it "keeps X-Frame-Options on the other pages of the app" do
    get "/up"

    expect(response.headers["X-Frame-Options"]).to eq("SAMEORIGIN")
  end
end
