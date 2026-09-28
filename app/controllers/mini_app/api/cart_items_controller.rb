# frozen_string_literal: true

module MiniApp
  module Api
    # Cart lines. Every action answers with the whole cart.
    #
    #   POST   /app/:bot_id/api/cart/items {"menu_item_id":1, "size":"medium"|null, "qty":1}
    #          adds a line or merges it with the same item and size (capped at 20)
    #   PATCH  /app/:bot_id/api/cart/items/:index {"qty":3} - 1..20, 0 removes the line
    #   DELETE /app/:bot_id/api/cart/items/:index
    class CartItemsController < BaseController
      def create
        qty = params.key?(:qty) ? integer_param(params[:qty]) : 1
        return render_error("invalid_qty", :unprocessable_content) unless qty&.positive?

        item = find_available_item
        size_known, size = item ? size_for(item, params[:size]) : [ false, nil ]
        return render_error("item_unavailable", :unprocessable_content) unless size_known

        draft = Draft.get_or_create(telegram_user_id)
        draft.add_item_with_size(item, size, qty)
        render json: cart_json(draft)
      end

      def update
        draft = current_draft
        index = line_index(draft)
        return render_error("not_found", :not_found) unless index

        qty = integer_param(params[:qty])
        return render_error("invalid_qty", :unprocessable_content) unless qty&.between?(0, Draft::MAX_QTY_PER_LINE)

        qty.zero? ? draft.remove_item(index) : draft.update_item_qty(index, qty)
        render json: cart_json(draft)
      end

      def destroy
        draft = current_draft
        index = line_index(draft)
        return render_error("not_found", :not_found) unless index

        draft.remove_item(index)
        render json: cart_json(draft)
      end

      private

      # Only the current shop's items (tenant scope), only available ones
      def find_available_item
        id = integer_param(params[:menu_item_id])
        item = id && MenuItem.find_by(id: id)
        item if item&.available?
      end

      # A sized item without a size gets its default one; an item without sizes takes none
      #
      # @return [Array(Boolean, String | nil)] whether the size is valid for the item, the size
      def size_for(item, requested)
        return [ requested.nil?, nil ] unless item.has_sizes?

        size = requested.nil? ? MiniApp::ShopPresenter.default_size(item) : requested
        [ size.is_a?(String) && item.sizes.key?(size), size ]
      end

      # @return [Integer, nil] the :index path parameter if the cart has that line
      def line_index(draft)
        index = integer_param(request.path_parameters[:index].to_s)
        index if draft && index && index < draft.items.length
      end
    end
  end
end
