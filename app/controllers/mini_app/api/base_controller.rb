# frozen_string_literal: true

module MiniApp
  module Api
    # JSON API of a coffee shop's Mini App: /app/:bot_id/api/* (see plans/mini-app-api.md)
    #
    # Every request is resolved in this order:
    #   404 {"error":"not_found"}        unknown or inactive bot (bots are not tenant-scoped)
    #   503 {"error":"shop_unavailable"} the bot's coffee shop is not serving
    #   401 {"error":"unauthorized"}     X-Telegram-Init-Data missing, not signed with this
    #                                    bot's token, or expired
    # The action then runs inside the shop's tenant as the shop's Customer of the
    # initData user. Errors are always {"error": "<code>"}, never exception texts.
    class BaseController < ActionController::API
      INIT_DATA_HEADER = "X-Telegram-Init-Data"
      ID_FORMAT = /\A\d{1,18}\z/

      # Bodies are read with params[...] by the actions, unwrapped
      wrap_parameters false

      # Searched bottom-up: the generic handler goes first
      rescue_from StandardError, with: :internal_error
      rescue_from ActionDispatch::Http::Parameters::ParseError, with: :bad_request

      around_action :within_shop

      private

      attr_reader :current_bot, :current_customer

      def within_shop
        @current_bot = find_bot
        return render_error("not_found", :not_found) unless current_bot

        shop = current_bot.tenant
        return render_error("shop_unavailable", :service_unavailable) unless shop.serving?

        user = init_data_user
        return render_error("unauthorized", :unauthorized) unless user

        # with_tenant (not a bare assignment): the previous tenant is restored afterwards
        ActsAsTenant.with_tenant(shop) do
          @current_customer = Customer.from_init_data_user(user)
          yield
        end
      end

      # Path parameter only: `params` would parse the body
      def find_bot
        id = request.path_parameters[:bot_id].to_s
        Bot.find_by(id: id, active: true) if id.match?(ID_FORMAT)
      end

      # @return [Hash, nil] the "user" object of valid initData
      def init_data_user
        data = TelegramInitData.verify(request.headers[INIT_DATA_HEADER], bot_token: current_bot.token)
        user = data["user"]
        return user if user.is_a?(Hash) && user["id"].is_a?(Integer) && user["id"].positive?

        AppLog.info("Mini App request rejected: initData without a user", bot_id: current_bot.id)
        nil
      rescue TelegramInitData::Invalid => e
        AppLog.info("Mini App request rejected: invalid initData", bot_id: current_bot.id, reason: e.message)
        nil
      end

      def current_shop = ActsAsTenant.current_tenant
      def telegram_user_id = current_customer.telegram_user_id
      def current_draft = Draft.for_user(telegram_user_id)

      def shop_time_zone
        ActiveSupport::TimeZone[current_shop.time_zone.to_s] || Time.zone
      end

      def cart_json(draft = current_draft) = MiniApp::CartPresenter.new(draft).as_json

      def order_json(order) = MiniApp::OrderPresenter.new(order, time_zone: shop_time_zone).as_json

      # JSON integers, or digit strings (path / form parameters); anything else is nil
      def integer_param(value)
        case value
        when Integer then value
        when String then value.to_i if value.match?(ID_FORMAT)
        end
      end

      def render_error(code, status, **extra)
        render json: { error: code, **extra }, status: status
      end

      def bad_request(_exception)
        render_error("bad_request", :bad_request)
      end

      def internal_error(exception)
        AppLog.error("Mini App API error", path: request.path, error: "#{exception.class}: #{exception.message}",
                                           backtrace: exception.backtrace&.first(3)&.join(" | "))
        render_error("internal_error", :internal_server_error) unless performed?
      end
    end
  end
end
