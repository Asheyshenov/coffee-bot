# frozen_string_literal: true

module ShopBot
  # Telegram API client that retries a single call on 429 (waiting retry_after) and on
  # network trouble. Retrying the call, not the whole update, keeps the bot's side
  # effects (cart changes, orders) from running twice.
  class ResilientApi
    MAX_ATTEMPTS = 3
    MAX_WAIT = 5 # seconds; longer throttling is not worth holding a job for

    def initialize(api, sleeper: ->(seconds) { sleep(seconds) })
      @api = api
      @sleeper = sleeper
    end

    def method_missing(name, *args, **kwargs, &block)
      return super unless @api.respond_to?(name)

      attempt = 0
      begin
        attempt += 1
        @api.public_send(name, *args, **kwargs, &block)
      rescue Telegram::Bot::Exceptions::ResponseError => e
        raise unless e.error_code.to_i == 429 && attempt < MAX_ATTEMPTS

        @sleeper.call(retry_after(e))
        retry
      rescue Faraday::ConnectionFailed, Faraday::TimeoutError
        raise unless attempt < MAX_ATTEMPTS

        @sleeper.call(attempt)
        retry
      end
    end

    def respond_to_missing?(name, include_private = false) = @api.respond_to?(name, include_private) || super

    private

    def retry_after(error)
      seconds = error.respond_to?(:parameters) ? error.parameters.to_h["retry_after"] : nil
      seconds ||= JSON.parse(error.response.body).dig("parameters", "retry_after") rescue nil # rubocop:disable Style/RescueModifier
      seconds.to_i.clamp(1, MAX_WAIT)
    end
  end
end
