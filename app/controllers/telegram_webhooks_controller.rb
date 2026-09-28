# frozen_string_literal: true

# Telegram webhook of a coffee shop's bot: POST /tg/:bot_id
#
# The update is only queued here: Telegram waits for the response and retries slow or
# failed deliveries, so the work happens in ShopBot::ProcessUpdateJob.
class TelegramWebhooksController < ActionController::API
  SECRET_HEADER = "X-Telegram-Bot-Api-Secret-Token"
  SUPPORTED_UPDATES = %w[message callback_query].freeze

  # The body is parsed here (a broken body must not raise before the checks)
  wrap_parameters false

  def create
    # Bots are not tenant-scoped: the bot tells which coffee shop the update is for.
    # path_parameters: `params` would parse the JSON body.
    bot = Bot.find_by(id: request.path_parameters[:bot_id], active: true)
    return head :not_found unless bot
    return head :unauthorized unless bot.valid_webhook_secret?(request.headers[SECRET_HEADER])

    update = parse_update
    return head :bad_request unless update

    if !bot.tenant.serving?
      AppLog.info("Telegram update ignored: coffee shop is not serving", tenant_id: bot.tenant_id, bot_id: bot.id)
    elsif SUPPORTED_UPDATES.none? { |type| update.key?(type) }
      nil # other update types are not used
    elsif !TelegramUpdate.accept?(bot, update["update_id"])
      AppLog.info("Telegram update redelivered, already accepted", bot_id: bot.id, update_id: update["update_id"])
    else
      ShopBot::ProcessUpdateJob.perform_later(bot.tenant_id, bot.id, update)
    end

    head :ok
  end

  private

  # @return [Hash, nil] the update JSON, nil if the body is not a JSON object
  def parse_update
    json = JSON.parse(request.raw_post)
    json if json.is_a?(Hash)
  rescue JSON::ParserError
    nil
  end
end
