# frozen_string_literal: true

module MiniApp
  module Api
    # The customer's orders in this coffee shop
    #
    #   GET  /app/:bot_id/api/orders            {"orders": [...]} latest 10, newest first
    #   GET  /app/:bot_id/api/orders/:id
    #   POST /app/:bot_id/api/orders            {"comment": "..."} checkout of the cart
    #   POST /app/:bot_id/api/orders/:id/cancel {"outcome": "...", "order": {...}}
    #
    # Another customer's or another shop's order is 404.
    class OrdersController < BaseController
      RECENT_LIMIT = 10

      # Every checkout creates an MWallet invoice on the shop's account: a customer
      # (or a script with a valid initData) must not flood it
      rate_limit to: 5, within: 1.minute, only: :create,
                 by: -> { "mini-app-orders:#{current_bot.id}:#{telegram_user_id}" },
                 with: -> { render_error("too_many_requests", :too_many_requests) },
                 store: Rails.application.config.x.rate_limit_store || Rails.cache

      def index
        orders = customer_orders.includes(:order_items, :payment).limit(RECENT_LIMIT)
        render json: { orders: orders.map { |order| order_json(order) } }
      end

      def show
        order = find_order
        return render_error("not_found", :not_found) unless order

        render json: order_json(order)
      end

      # Like the chat checkout: the cart is checked against the menu first (409 with the
      # changes, the client confirms again), then the order and its MWallet invoice are
      # created and the cart is cleared. The payment data is in the order JSON: the chat
      # gets no QR message.
      def create
        comment = params[:comment]
        return render_error("invalid_comment", :unprocessable_content) unless comment.nil? || comment.is_a?(String)

        # One checkout per customer at a time: a double tap (or the chat and the app at
        # once) waits here, then finds the cart already turned into an order
        current_customer.with_lock do
          draft = current_draft
          changes = draft&.sync_with_menu!
          next render_cart_changed(draft, changes) if menu_changed?(changes)
          next render_error("empty_cart", :unprocessable_content) if draft.nil? || draft.empty?

          # Without the key the cart keeps its comment (e.g. one typed in the chat)
          draft.set_comment(comment) if params.key?(:comment)
          place_order(draft)
        end
      end

      # Same as /cancel in the chat: a last-chance payment check first; if that check is
      # what settled the order, its notifications are sent (winner only)
      def cancel
        order = find_order
        return render_error("not_found", :not_found) unless order

        outcome = OrderService.cancel_by_client(order) { |result| notify_payment_result(order, result) }
        render json: { outcome: outcome.to_s, order: order_json(order.reload) }
      end

      private

      def customer_orders
        Order.where(customer_id: current_customer.id).order(created_at: :desc, id: :desc)
      end

      def find_order
        id = integer_param(request.path_parameters[:id].to_s)
        id && customer_orders.find_by(id: id)
      end

      def place_order(draft)
        order = OrderService.create_from_draft(draft, current_customer)
        # An item went off the menu right after the check
        return render_order_not_created(draft) unless order

        begin
          OrderService.create_invoice(order)
        rescue StandardError => e
          # Details are logged by OrderService; provider texts are not for customers.
          # The cart stays, so the customer can retry.
          AppLog.error("Mini App order: invoice not created, cart kept", order_id: order.id, error: e.class.name)
          return render_error("invoice_failed", :bad_gateway)
        end

        Draft.clear(telegram_user_id)
        AppLog.info("Mini App order placed", order_id: order.id, total: order.total_amount)
        render json: order_json(order.reload), status: :created
      end

      def render_order_not_created(draft)
        changes = draft.sync_with_menu!
        return render_cart_changed(draft, changes) if menu_changed?(changes)

        render_error("empty_cart", :unprocessable_content)
      end

      def menu_changed?(changes) = changes.present? && (changes[:removed].any? || changes[:repriced].any?)

      def render_cart_changed(draft, changes)
        render_error("cart_changed", :conflict, removed: changes[:removed], repriced: changes[:repriced],
                                                cart: cart_json(draft))
      end

      def notify_payment_result(order, result)
        Payments::NotifyResultJob.notify_later(order, result)
      rescue StandardError => e
        AppLog.error("Failed to queue payment notifications", order_id: order.id, error: "#{e.class}: #{e.message}")
      end
    end
  end
end
