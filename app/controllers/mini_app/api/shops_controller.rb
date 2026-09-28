# frozen_string_literal: true

module MiniApp
  module Api
    # GET /app/:bot_id/api/shop - the coffee shop and its available menu
    class ShopsController < BaseController
      def show
        items = MenuItem.available.ordered_by_category.to_a
        render json: MiniApp::ShopPresenter.new(current_shop, items).as_json
      end
    end
  end
end
