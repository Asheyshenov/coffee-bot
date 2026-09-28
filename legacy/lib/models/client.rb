# frozen_string_literal: true

# Client Model
# Represents a Telegram user who uses the bot

require_relative '../../config/boot'

class Client < Sequel::Model
  # Allow setting telegram_user_id (primary key) via mass assignment
  unrestrict_primary_key

  # Validations
  def validate
    super
    errors.add(:telegram_user_id, 'cannot be nil') if telegram_user_id.nil?
  end

  # Scopes
  dataset_module do
    def ordered_by_name
      order(:first_name, :last_name)
    end

    def with_orders
      where { orders_count > 0 }
    end

    def recent(limit = 10)
      order(Sequel.desc(:last_order_at)).limit(limit)
    end
  end

  # Class methods

  # Find or create a client from Telegram message
  def self.find_or_create_from_message(message)
    user = message.from
    find_or_create(telegram_user_id: user.id) do |client|
      client.telegram_user_id = user.id
      client.username = user.username
      client.first_name = user.first_name
      client.last_name = user.last_name
      client.language_code = user.language_code
      client.orders_count = 0
    end
  end

  # Instance methods

  # Display name for orders
  def display_name
    parts = [first_name, last_name].compact.reject(&:empty?)
    if parts.any?
      parts.join(' ')
    elsif username
      "@#{username}"
    else
      "User #{telegram_user_id}"
    end
  end

  # Mention format (for Telegram notifications)
  def mention
    if username
      "@#{username}"
    else
      "[#{display_name}](tg://user?id=#{telegram_user_id})"
    end
  end

  # Increment order count
  def increment_orders!
    update(
      orders_count: orders_count + 1,
      last_order_at: Time.now.utc
    )
  end

  # Full name
  def full_name
    [first_name, last_name].compact.reject(&:empty?).join(' ')
  end

  # String representation
  def to_s
    display_name
  end
end
