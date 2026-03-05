# frozen_string_literal: true

# Order Service
# Handles order lifecycle and business logic

require_relative '../../config/boot'
require_relative 'mwallet/mwallet_service'

module CoffeeBot
  module Services
    class OrderService
      # Create order from draft
      #
      # @param draft [Draft] The draft with cart items
      # @param client [Client] The client making the order
      # @return [Order] Created order
      def self.create_from_draft(draft, client)
        order = Order.create_from_draft(draft, client)
        
        log_info('Order created',
          order_id: order.id,
          client: client.display_name,
          total: order.formatted_total
        )
        
        order
      end

      # Create invoice for order
      #
      # @param order [Order] The order to create invoice for
      # @return [Hash] Invoice data with payment link
      def self.create_invoice(order)
        mwallet = MWallet::Service.new
        mwallet.create_invoice_for_order(order)
      rescue MWalletError::Base => e
        log_error('Failed to create invoice', order_id: order.id, error: e.message)
        raise
      end

      # Get orders for client
      #
      # @param telegram_user_id [Integer] Telegram user ID
      # @param limit [Integer] Maximum number of orders
      # @return [Array<Order>] List of orders
      def self.client_orders(telegram_user_id, limit: 10)
        Order.for_user(telegram_user_id).limit(limit).all
      end

      # Get active order for client (if any)
      #
      # @param telegram_user_id [Integer] Telegram user ID
      # @return [Order, nil] Active order or nil
      def self.active_order_for_client(telegram_user_id)
        Order.where(telegram_user_id: telegram_user_id, status: OrderStatus::ACTIVE).first
      end

      # Get queue for barista (PAID orders)
      #
      # @return [Array<Order>] List of orders in queue
      def self.barista_queue
        Order.ready_for_barista.all
      end

      # Get orders in progress for barista
      #
      # @param barista_id [Integer] Barista telegram ID
      # @return [Array<Order>] List of orders
      def self.barista_in_progress(barista_id)
        Order.for_barista(barista_id).all
      end

      # Claim order for barista (atomic operation)
      #
      # @param order_id [Integer] Order ID
      # @param barista_id [Integer] Barista telegram ID
      # @return [Boolean] True if claimed successfully
      def self.claim_order(order_id, barista_id)
        order = Order[order_id]
        return false unless order
        
        order.claim_for_barista!(barista_id)
      end

      # Complete order (mark as ready)
      #
      # @param order_id [Integer] Order ID
      # @param barista_id [Integer] Barista telegram ID
      # @return [Boolean] True if completed successfully
      def self.complete_order(order_id, barista_id)
        order = Order[order_id]
        return false unless order
        return false unless order.assigned_to_barista_id == barista_id
        
        order.mark_ready!
      end

      # Cancel order
      #
      # @param order_id [Integer] Order ID
      # @param reason [String] Cancellation reason
      # @return [Boolean] True if cancelled
      def self.cancel_order(order_id, reason = nil)
        order = Order[order_id]
        return false unless order
        
        # MWallet doesn't have cancel API in v1, just mark as cancelled locally
        if order.invoice_id_provider && order.status == OrderStatus::INVOICE_CREATED
          order.cancel!(reason)
        else
          order.cancel!(reason)
        end
      end

      # Sync order status with payment provider
      #
      # @param order [Order] Order to sync
      # @return [Boolean] True if status was updated
      def self.sync_payment_status(order)
        return false unless order.invoice_id_provider
        
        mwallet = MWallet::Service.new
        mwallet.sync_status(order)
      end

      # Expire old invoices
      #
      # @param expire_minutes [Integer] Minutes before expiration
      # @return [Integer] Number of expired orders
      def self.expire_old_invoices(expire_minutes = nil)
        expire_minutes ||= CoffeeBot::Config::ORDER_EXPIRE_MINUTES
        
        cutoff_time = Time.now.utc - (expire_minutes * 60)
        
        # Use bulk update instead of N+1 queries
        # This updates all matching orders in a single SQL statement
        count = DB.transaction do
          # Lock and update in bulk for consistency
          affected_ids = Order
            .for_update
            .where(status: OrderStatus::INVOICE_CREATED)
            .where(Sequel.lit('created_at < ?', cutoff_time))
            .select_map(:id)
          
          if affected_ids.empty?
            0
          else
            # Bulk update status
            Order.where(id: affected_ids).update(status: OrderStatus::EXPIRED)
            
            # Log each expired order (optional, can be batched)
            affected_ids.each do |order_id|
              log_info('Order expired', order_id: order_id)
            end
            
            affected_ids.size
          end
        end
        
        count
      end

      # Get order statistics
      #
      # @param date [Date] Date to get stats for
      # @return [Hash] Statistics
      def self.statistics(date = Date.today)
        orders = Order.where(
          created_at: date.to_time..(date + 1).to_time
        )
        
        {
          total: orders.count,
          paid: orders.where(status: OrderStatus::PAID).count,
          in_progress: orders.where(status: OrderStatus::IN_PROGRESS).count,
          completed: orders.where(status: OrderStatus::READY).count,
          cancelled: orders.where(status: OrderStatus::CANCELLED).count,
          revenue: orders.where(status: [OrderStatus::PAID, OrderStatus::IN_PROGRESS, OrderStatus::READY])
                        .sum(:total_amount) || 0
        }
      end

      # Process payment callback
      #
      # @param params [Hash] Callback parameters
      # @param raw_body [String] Raw request body
      # @return [Boolean] True if processed
      def self.process_payment_callback(params, raw_body)
        mwallet = MWallet::Service.new
        mwallet.process_callback(params, raw_body)
      end
    end
  end
end
