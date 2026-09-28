Rails.application.routes.draw do
  # Load balancer / uptime health check
  get "up" => "rails/health#show", as: :rails_health_check

  # Telegram webhook of a coffee shop's bot (secret checked via X-Telegram-Bot-Api-Secret-Token)
  post "tg/:bot_id" => "telegram_webhooks#create", as: :telegram_webhook

  # O!Dengi MWallet payment result (result_url of every invoice of that payment account)
  post "pay/mwallet/:payment_account_id" => "mwallet_callbacks#create", as: :mwallet_callback

  # Telegram Mini App of a coffee shop's bot (customer menu, cart, checkout, order status).
  # The page is a shell; data comes from the JSON API below, authenticated with the
  # Telegram initData of the bot (X-Telegram-Init-Data header). See plans/mini-app-api.md
  scope "app/:bot_id", as: :mini_app do
    get "/" => "mini_app/pages#show", as: :root

    scope "api", module: "mini_app/api", as: :api, defaults: { format: :json } do
      get "shop" => "shops#show"
      get "cart" => "carts#show"
      delete "cart" => "carts#destroy"
      post "cart/items" => "cart_items#create"
      patch "cart/items/:index" => "cart_items#update", constraints: { index: /\d+/ }
      delete "cart/items/:index" => "cart_items#destroy", constraints: { index: /\d+/ }
      resources :orders, only: %i[index show create] do
        post :cancel, on: :member
      end
    end
  end
end
