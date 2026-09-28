# frozen_string_literal: true

module MiniApp
  # The customer Mini App page of a coffee shop's bot: GET /app/:bot_id
  #
  # A static shell: the JS (app/javascript/mini_app) reads Telegram.WebApp.initData and
  # loads everything from the JSON API under /app/:bot_id/api. initData lives in the URL
  # fragment, which browsers never send, so this page needs no authentication.
  # See plans/mini-app-api.md
  class PagesController < ActionController::Base
    # Telegram Desktop and Web show Mini Apps in an iframe of web.telegram.org
    FRAME_ANCESTORS = %w[https://web.telegram.org https://*.telegram.org].freeze
    # Mini App modules preloaded by the page (the admin's Turbo / Stimulus are not needed)
    MODULE_PREFIX = "mini_app/"
    ENTRY_POINT = "mini_app/app"

    layout "mini_app"

    content_security_policy { |policy| policy.frame_ancestors(*FRAME_ANCESTORS) }
    # /app/1.json is the same page (the route accepts a format)
    before_action { request.format = :html }
    after_action :allow_telegram_frames

    helper_method :mini_app_module_paths

    def show
      # Bots are not tenant-scoped: the bot tells which coffee shop this is
      @bot = Bot.find_by(id: params[:bot_id], active: true)
      return render :not_found, status: :not_found unless @bot

      @tenant = @bot.tenant
      return render :unavailable, status: :service_unavailable unless @tenant.serving?

      @api_base = "#{mini_app_root_path(bot_id: @bot.id)}/api"
    end

    private

    # Replaces the SAMEORIGIN default: CSP frame-ancestors decides who may embed the page
    def allow_telegram_frames
      response.headers.delete("X-Frame-Options")
    end

    # Digested URLs of the Mini App modules, for <link rel="modulepreload">
    def mini_app_module_paths
      @mini_app_module_paths ||= Rails.application.importmap
        .preloaded_module_packages(resolver: helpers, entry_point: ENTRY_POINT, cache_key: ENTRY_POINT)
        .select { |_path, package| package.name.start_with?(MODULE_PREFIX) }
        .keys
    end
  end
end
