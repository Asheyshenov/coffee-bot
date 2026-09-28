# frozen_string_literal: true

require "openssl"

# Verifies the initData a Telegram Mini App sends (Telegram.WebApp.initData), see
# "Validating data received via the Mini App" in the Telegram docs:
#
#   secret_key        = HMAC_SHA256(key: "WebAppData", data: bot_token)
#   data_check_string = every field except "hash", sorted by key, "key=value" joined by "\n"
#   hash             == hex(HMAC_SHA256(key: secret_key, data: data_check_string))
#
#   data = TelegramInitData.verify(header, bot_token: bot.token)
#   data["user"]["id"] # => 1001
class TelegramInitData
  class Invalid < StandardError; end

  # Real initData is well below 1 KB
  MAX_LENGTH = 8192
  HASH_FORMAT = /\A\h{64}\z/

  # @param init_data [String] the raw query string
  # @param bot_token [String] token of the bot the Mini App was opened from
  # @param max_age [ActiveSupport::Duration] oldest auth_date accepted
  # @return [Hash] the signed fields (String keys, without "hash"): "auth_date" as an
  #   Integer, "user" parsed from JSON (a Hash), the others as Strings
  # @raise [Invalid] missing, malformed, not signed with this bot's token, or expired
  def self.verify(init_data, bot_token:, max_age: 24.hours)
    raise Invalid, "bot token missing" if bot_token.blank?

    fields = parse(init_data)
    received_hash = fields.delete("hash").to_s.downcase
    raise Invalid, "hash missing or malformed" unless received_hash.match?(HASH_FORMAT)
    raise Invalid, "hash mismatch" unless ActiveSupport::SecurityUtils.secure_compare(signature(fields, bot_token), received_hash)

    fields["auth_date"] = auth_date!(fields["auth_date"], max_age)
    fields["user"] = parse_user(fields["user"]) if fields.key?("user")
    fields
  end

  # @return [Hash{String => String}]
  def self.parse(init_data)
    raise Invalid, "init data missing" unless init_data.is_a?(String) && init_data.present?
    raise Invalid, "init data too long" if init_data.bytesize > MAX_LENGTH

    pairs = URI.decode_www_form(init_data)
    fields = pairs.to_h
    # A repeated key would make the checked string ambiguous
    raise Invalid, "duplicate field" unless fields.size == pairs.size

    fields
  rescue ArgumentError
    raise Invalid, "init data malformed"
  end

  def self.signature(fields, bot_token)
    data_check_string = fields.sort.map { |key, value| "#{key}=#{value}" }.join("\n")
    secret_key = OpenSSL::HMAC.digest("SHA256", "WebAppData", bot_token)
    OpenSSL::HMAC.hexdigest("SHA256", secret_key, data_check_string)
  end

  def self.auth_date!(value, max_age)
    raise Invalid, "auth_date missing" unless value.to_s.match?(/\A\d{1,12}\z/)

    auth_date = value.to_i
    raise Invalid, "init data expired" if Time.zone.at(auth_date) < max_age.ago

    auth_date
  end

  def self.parse_user(value)
    user = JSON.parse(value.to_s)
    raise Invalid, "user is not an object" unless user.is_a?(Hash)

    user
  rescue JSON::ParserError
    raise Invalid, "user is not valid JSON"
  end

  private_class_method :parse, :signature, :auth_date!, :parse_user
end
