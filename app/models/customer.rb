# frozen_string_literal: true

# A Telegram user ordering in one coffee shop (the same person may be a customer of several)
class Customer < ApplicationRecord
  acts_as_tenant :tenant

  has_many :orders, dependent: :restrict_with_error

  validates :telegram_user_id, presence: true, uniqueness: { scope: :tenant_id }

  # Find or create the customer of the current tenant for a Telegram user and
  # refresh the profile fields (names change)
  #
  # @param user [Telegram::Bot::Types::User]
  def self.from_telegram(user)
    customer = create_or_find_by!(telegram_user_id: user.id)
    customer.update!(username: user.username, first_name: user.first_name, last_name: user.last_name,
                     language_code: user.language_code)
    customer
  end

  # Name shown to baristas
  def display_name
    full = [first_name, last_name].compact_blank.join(" ")
    return full if full.present?

    username.present? ? "@#{username}" : "User #{telegram_user_id}"
  end

  def increment_orders!
    self.class.where(id: id).update_all(["orders_count = orders_count + 1, last_order_at = ?", Time.current])
    reload
  end
end
