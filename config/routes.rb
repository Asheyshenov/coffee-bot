Rails.application.routes.draw do
  # Load balancer / uptime health check
  get "up" => "rails/health#show", as: :rails_health_check

  # Telegram webhook of a coffee shop's bot (secret checked via X-Telegram-Bot-Api-Secret-Token)
  post "tg/:bot_id" => "telegram_webhooks#create", as: :telegram_webhook

  # O!Dengi MWallet payment result (result_url of every invoice of that payment account)
  post "pay/mwallet/:payment_account_id" => "mwallet_callbacks#create", as: :mwallet_callback
end
