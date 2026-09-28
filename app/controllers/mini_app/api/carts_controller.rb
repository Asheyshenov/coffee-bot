# frozen_string_literal: true

module MiniApp
  module Api
    # The customer's cart: the same Draft the chat bot uses
    #
    #   GET    /app/:bot_id/api/cart
    #   DELETE /app/:bot_id/api/cart - empties it
    class CartsController < BaseController
      def show
        render json: cart_json
      end

      def destroy
        Draft.clear(telegram_user_id)
        render json: cart_json(nil)
      end
    end
  end
end
