# frozen_string_literal: true

require "openssl"

# Telegram Mini App initData for specs, signed like Telegram does
# (see TelegramInitData), and requests to the Mini App API of a bot.
#
#   mini_app_get("cart")                                  # as client_id, current shop's bot
#   mini_app_post("cart/items", { menu_item_id: 1 })
#   mini_app_get("shop", init_data: expired_init_data)
module MiniAppApiHelpers
  TEST_BOT_TOKEN = "123:TEST" # token of every bot made by TenancyHelpers#create_tenant

  # A valid initData string
  #
  # @param user [Hash] merged into the default user; nil removes the "user" field
  def init_data_for(user_id: TenancyHelpers::CLIENT_ID, bot_token: TEST_BOT_TOKEN, auth_date: Time.current.to_i,
                    user: {}, **fields)
    data = { "auth_date" => auth_date.to_s, "query_id" => "AAHdF6IQAAAAAN0XohDhrOrc", **fields.transform_keys(&:to_s) }
    unless user.nil?
      data["user"] = { id: user_id, first_name: "Айбек", last_name: "Т", username: "aibek", language_code: "ru",
                       allows_write_to_pm: true }.merge(user).to_json
    end
    signed_init_data(data, bot_token: bot_token)
  end

  # @param fields [Hash{String => String}] everything but "hash"
  def signed_init_data(fields, bot_token: TEST_BOT_TOKEN)
    data_check_string = fields.sort.map { |key, value| "#{key}=#{value}" }.join("\n")
    secret_key = OpenSSL::HMAC.digest("SHA256", "WebAppData", bot_token)
    URI.encode_www_form(fields.merge("hash" => OpenSSL::HMAC.hexdigest("SHA256", secret_key, data_check_string)))
  end

  # Signed correctly, but auth_date is older than 24 h
  def expired_init_data(**options) = init_data_for(auth_date: 25.hours.ago.to_i, **options)

  # Signed for one user, then the user id was changed
  def tampered_init_data(user_id: TenancyHelpers::CLIENT_ID, to_user_id: TenancyHelpers::STRANGER_ID)
    fields = URI.decode_www_form(init_data_for(user_id: user_id)).to_h
    user = JSON.parse(fields["user"]).merge("id" => to_user_id)
    URI.encode_www_form(fields.merge("user" => user.to_json))
  end

  def mini_app_path(path, bot: current_tenant.bot) = "/app/#{bot.id}/api/#{path}"

  def mini_app_headers(init_data)
    headers = { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json" }
    headers[MiniApp::Api::BaseController::INIT_DATA_HEADER] = init_data if init_data
    headers
  end

  def mini_app_get(path, bot: current_tenant.bot, init_data: init_data_for)
    get mini_app_path(path, bot: bot), headers: mini_app_headers(init_data)
  end

  %i[post patch delete].each do |verb|
    define_method(:"mini_app_#{verb}") do |path, body = nil, bot: current_tenant.bot, init_data: init_data_for|
      params = body.is_a?(String) || body.nil? ? body : body.to_json
      public_send(verb, mini_app_path(path, bot: bot), params: params, headers: mini_app_headers(init_data))
    end
  end
end

RSpec.configure do |config|
  config.include MiniAppApiHelpers
end
