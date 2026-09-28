# frozen_string_literal: true

module ShopBot
  # Handles one Telegram update of a coffee shop's bot (queued by TelegramWebhooksController)
  #
  #   ShopBot::ProcessUpdateJob.perform_later(bot.tenant_id, bot.id, update_json_hash)
  class ProcessUpdateJob < TenantJob
    queue_as :default

    # Updates of one user are handled one at a time, in arrival order: they change the
    # same cart, and a double tap must see the result of the first tap
    limits_concurrency to: 1, duration: 2.minutes,
                       key: ->(_tenant_id, bot_id, update) { "#{bot_id}:#{ProcessUpdateJob.sender_key(update)}" }

    # Telegram user (or chat) the update comes from
    def self.sender_key(update)
      update = update.to_h
      update.dig("message", "from", "id") || update.dig("callback_query", "from", "id") ||
        update.dig("message", "chat", "id") || "update-#{update['update_id']}"
    end

    # @param update [Hash] Telegram Update JSON (string keys)
    def perform_in_tenant(bot_id, update)
      # The bot must belong to the job's coffee shop
      bot = Bot.find_by(id: bot_id, tenant_id: ActsAsTenant.current_tenant.id, active: true)
      return AppLog.warn("Telegram update skipped: bot not found or inactive", bot_id: bot_id) unless bot

      Router.new(bot).handle(Telegram::Bot::Types::Update.new(update).current_message)
    rescue StandardError => e
      # The update is not retried: it may have changed the cart / created an order
      # before failing. Single Telegram calls already retry (ShopBot::ResilientApi).
      log_failure(e, bot_id, update)
    end

    private

    def log_failure(error, bot_id, update)
      AppLog.error("Failed to handle Telegram update", bot_id: bot_id, update_id: update.to_h["update_id"],
                                                       error: "#{error.class}: #{error.message}",
                                                       backtrace: error.backtrace&.first(3)&.join(" | "))
    end
  end
end
