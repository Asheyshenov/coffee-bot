# frozen_string_literal: true

# Connects a coffee shop's Telegram bot (token from @BotFather) to the platform:
# checks the token, stores the bot, points its webhook here, sets the command menu and
# the chat menu button that opens the customer Mini App.
#
#   bot = BotRegistration.new(tenant: tenant, token: "123456:ABC...").call
#   BotRegistration.refresh(tenant.bot) # same setup again for a connected bot, no new token
class BotRegistration
  class Error < StandardError; end
  # The token is malformed or Telegram does not know it
  class InvalidToken < Error; end
  # The Telegram bot is already connected to another coffee shop
  class AlreadyConnected < Error; end
  # Telegram API failure or unreachable
  class TelegramError < Error; end

  TOKEN_FORMAT = /\A\d+:[\w-]+\z/
  ALLOWED_UPDATES = %w[message callback_query].freeze
  COMMANDS = [
    { command: "start", description: "Начать работу с ботом" },
    { command: "order", description: "Сделать заказ" },
    { command: "my_orders", description: "Мои заказы" },
    { command: "cancel", description: "Отменить текущий заказ" },
    { command: "help", description: "Справка" }
  ].freeze
  MENU_BUTTON_TEXT = "☕ Меню"

  attr_reader :tenant

  # Re-applies the webhook, the command menu and the Mini App menu button of an already
  # connected bot (e.g. after PUBLIC_BASE_URL changed). Updates waiting in Telegram are kept.
  #
  # @return [Hash] { webhook: true, commands: Boolean, menu_button: true | false | :skipped }
  # @raise [Error] the bot is not active; [TelegramError] Telegram refused the webhook
  def self.refresh(bot) = new(tenant: bot.tenant, token: bot.token).refresh(bot)

  def initialize(tenant:, token:)
    @tenant = tenant
    @token = token.to_s.strip
  end

  # @return [Bot] the tenant's active bot
  # @raise [InvalidToken, AlreadyConnected, TelegramError]
  def call
    raise InvalidToken, "Malformed bot token" unless @token.match?(TOKEN_FORMAT)

    me = fetch_me
    previous = []
    bot = Bot.transaction do
      bot = save_bot!(me)
      previous = tenant.bots.where(active: true).where.not(id: bot.id).to_a
      Bot.where(id: previous.map(&:id)).update_all(active: false, updated_at: Time.current)
      # Inside the transaction: if Telegram refuses the webhook, nothing is saved
      set_webhook!(bot)
      bot
    end

    set_commands(bot)
    set_menu_button(bot)
    previous.each { |old_bot| delete_webhook(old_bot) }
    AppLog.info("Bot connected", tenant_id: tenant.id, bot_id: bot.id, username: bot.username)
    bot
  rescue ActiveRecord::RecordNotUnique
    # Another coffee shop connected the same bot at the same moment
    raise AlreadyConnected, "@#{me&.username} is already connected to another coffee shop"
  end

  # @see .refresh
  def refresh(bot)
    raise Error, "@#{bot.username} is not the active bot of this coffee shop" unless bot.active? && bot.tenant_id == tenant.id

    set_webhook!(bot, drop_pending_updates: false)
    result = { webhook: true, commands: set_commands(bot), menu_button: set_menu_button(bot) }
    AppLog.info("Bot refreshed", tenant_id: tenant.id, bot_id: bot.id, commands: result[:commands], menu_button: result[:menu_button])
    result
  end

  private

  # Client of the new token (a reused Bot record may still cache a client of the old one)
  def api = @api ||= Telegram::Bot::Client.new(@token).api

  # @return [Telegram::Bot::Types::User]
  def fetch_me
    me = api.get_me
    me = Telegram::Bot::Types::User.new(me.fetch("result", me)) if me.is_a?(Hash)
    raise InvalidToken, "The token does not belong to a bot" unless me.is_bot && me.username.present?

    me
  rescue Telegram::Bot::Exceptions::ResponseError => e
    raise InvalidToken, "Telegram rejected the bot token" if e.error_code.to_i.in?([ 401, 404 ])

    raise TelegramError, "getMe failed (#{e.error_code})"
  rescue Dry::Struct::Error, KeyError
    raise TelegramError, "Unexpected getMe response"
  rescue Faraday::Error => e
    raise TelegramError, "Telegram is unreachable (#{e.class.name})"
  end

  def save_bot!(me)
    existing = Bot.lock.find_by(telegram_bot_id: me.id)
    raise AlreadyConnected, "@#{me.username} is already connected to another coffee shop" if existing && existing.tenant_id != tenant.id

    bot = existing || Bot.new(tenant: tenant, telegram_bot_id: me.id)
    bot.update!(token: @token, username: me.username, active: true)
    bot
  end

  def set_webhook!(bot, drop_pending_updates: true)
    api.set_webhook(url: bot.webhook_url, secret_token: bot.webhook_secret,
                    allowed_updates: ALLOWED_UPDATES, drop_pending_updates: drop_pending_updates)
  rescue Telegram::Bot::Exceptions::ResponseError => e
    raise TelegramError, "setWebhook failed (#{e.error_code}): #{e.data['description'] || e.data[:description]}"
  rescue Faraday::Error => e
    raise TelegramError, "Telegram is unreachable (#{e.class.name})"
  end

  # The command menu is a convenience: a failure does not undo the registration
  #
  # @return [Boolean] whether Telegram accepted it
  def set_commands(bot)
    api.set_my_commands(commands: COMMANDS)
    true
  rescue StandardError => e
    AppLog.warn("setMyCommands failed", bot_id: bot.id, error: e.class.name)
    false
  end

  # The "☕ Меню" button next to the input field opens the Mini App (best effort, like the
  # command menu). Telegram accepts only HTTPS Mini App URLs: skipped for a local http setup.
  #
  # @return [true, false, :skipped]
  def set_menu_button(bot)
    unless bot.mini_app_available?
      AppLog.info("Mini App menu button skipped: PUBLIC_BASE_URL is not https", bot_id: bot.id)
      return :skipped
    end

    api.set_chat_menu_button(menu_button: { type: "web_app", text: MENU_BUTTON_TEXT, web_app: { url: bot.mini_app_url } })
    true
  rescue StandardError => e
    AppLog.warn("setChatMenuButton failed", bot_id: bot.id, error: e.class.name)
    false
  end

  # Stop Telegram from delivering updates of a replaced bot (best effort)
  def delete_webhook(old_bot)
    old_bot.api.delete_webhook
  rescue StandardError => e
    AppLog.warn("deleteWebhook of the previous bot failed", bot_id: old_bot.id, error: e.class.name)
  end
end
