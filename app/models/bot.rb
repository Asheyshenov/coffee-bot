# frozen_string_literal: true

# The coffee shop's own Telegram bot (created by the owner in @BotFather).
# Not tenant-scoped: an incoming webhook is routed to its tenant through the bot.
class Bot < ApplicationRecord
  belongs_to :tenant
  has_many :telegram_updates, dependent: :delete_all

  encrypts :token

  validates :token, :username, :telegram_bot_id, :webhook_secret, presence: true
  validates :telegram_bot_id, uniqueness: true

  before_validation :generate_webhook_secret, on: :create

  # Telegram API client of this bot
  def api
    @api ||= ShopBot::ResilientApi.new(Telegram::Bot::Client.new(token).api)
  end

  # Where Telegram delivers updates for this bot
  def webhook_url
    "#{Rails.configuration.x.public_base_url}/tg/#{id}"
  end

  # Constant-time check of the X-Telegram-Bot-Api-Secret-Token header
  def valid_webhook_secret?(value)
    value.present? && ActiveSupport::SecurityUtils.secure_compare(value, webhook_secret)
  end

  private

  # Telegram allows A-Z, a-z, 0-9, _ and -, up to 256 characters
  def generate_webhook_secret
    self.webhook_secret ||= SecureRandom.alphanumeric(48)
  end
end
