# frozen_string_literal: true

# A Telegram user ordering in one coffee shop (the same person may be a customer of several)
class Customer < ApplicationRecord
  acts_as_tenant :tenant

  has_many :orders, dependent: :restrict_with_error

  # Uniqueness per shop is enforced by the unique index; a uniqueness validation would
  # make create_or_find_by! raise RecordInvalid for returning customers
  validates :telegram_user_id, presence: true

  # Find or create the customer of the current tenant for a Telegram user and
  # refresh the profile fields (names change)
  #
  # @param user [Telegram::Bot::Types::User]
  def self.from_telegram(user)
    with_profile(user.id, username: user.username, first_name: user.first_name, last_name: user.last_name,
                          language_code: user.language_code)
  end

  # Same for the "user" object of verified Mini App initData (see TelegramInitData)
  #
  # @param user [Hash] "id" (Integer), "username", "first_name", "last_name", "language_code"
  def self.from_init_data_user(user)
    profile = %w[username first_name last_name language_code].to_h do |field|
      value = user[field]
      [ field.to_sym, value.is_a?(String) ? value : nil ]
    end
    with_profile(user.fetch("id"), **profile)
  end

  def self.with_profile(telegram_user_id, **profile)
    customer = find_by(telegram_user_id: telegram_user_id) || create_or_find_by!(telegram_user_id: telegram_user_id)
    customer.update!(profile)
    customer
  end
  private_class_method :with_profile

  # Name shown to baristas
  def display_name
    full = [ first_name, last_name ].compact_blank.join(" ")
    return full if full.present?

    username.present? ? "@#{username}" : "User #{telegram_user_id}"
  end

  def increment_orders!
    self.class.where(id: id).update_all([ "orders_count = orders_count + 1, last_order_at = ?", Time.current ])
    reload
  end
end
