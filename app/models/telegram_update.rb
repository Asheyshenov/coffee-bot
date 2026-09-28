# frozen_string_literal: true

# Accepted Telegram update ids (per bot), for dropping redeliveries
class TelegramUpdate < ApplicationRecord
  KEEP_FOR = 3.days

  belongs_to :bot

  # Remember an update; false if it was already accepted (a redelivery)
  def self.accept?(bot, update_id)
    return true if update_id.nil?

    insert({ bot_id: bot.id, update_id: update_id, created_at: Time.current },
           unique_by: %i[bot_id update_id]).rows.any?
  end

  def self.prune! = where(created_at: ...KEEP_FOR.ago).delete_all
end
