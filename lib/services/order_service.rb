# frozen_string_literal: true

# Order Service
# Handles order lifecycle and business logic

require_relative '../../config/boot'
require_relative '../models/order_status'
require_relative 'mwallet/mwallet_service'

module CoffeeBot
  module Services
    class OrderService
      # Statuses a client may cancel by themselves (nothing has been charged yet)
      CLIENT_CANCELLABLE = [OrderStatus::NEW, OrderStatus::INVOICE_CREATED].freeze

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

      # Get all active orders for client
      #
      # @param telegram_user_id [Integer] Telegram user ID
      # @return [Array<Order>] List of active orders
      def self.active_orders_for_client(telegram_user_id)
        Order.where(telegram_user_id: telegram_user_id, status: OrderStatus::ACTIVE).all
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

      # Cancel order on the client's request (/cancel)
      #
      # Only unpaid orders (NEW / INVOICE_CREATED) are cancelled. Before cancelling an
      # invoice a last-chance payment sync is done, so a payment that has just arrived
      # is not thrown away. PAID / IN_PROGRESS orders are never cancelled here: that
      # requires a refund and goes through the barista.
      #
      # If that sync is the one that changed the order (payment found, or a payment that
      # must not be accepted, e.g. too small), nobody else will announce it: the sync
      # result is yielded so the caller sends the notifications
      # (Notifier#notify_payment_result), just like StatusSyncer / callback do.
      #
      # @param order [Order] The order to cancel
      # @yieldparam sync_result [Hash] Result of #sync_payment_status (:notify_barista or :payment_error set)
      # @return [Symbol] Outcome:
      #   :cancelled         - order cancelled (invoice cancelled at provider, or there was none)
      #   :cancelled_locally - order cancelled, but the provider did not confirm the invoice cancel
      #   :paid_now          - last-chance sync found the payment (result yielded)
      #   :payment_problem   - last-chance sync found a payment that was rejected, order is ERROR (result yielded)
      #   :already_paid      - order is already paid and waiting in the queue
      #   :in_progress       - barista is already preparing the order
      #   :not_cancellable   - order is in another state (e.g. expired meanwhile)
      def self.cancel_by_client(order)
        outcome = client_cancel_blocker(order)

        if outcome.nil? && order.status == OrderStatus::INVOICE_CREATED
          result = last_chance_sync(order)
          settled = result[:notify_barista] || result[:payment_error] || result[:refund_required]
          yield result if settled && block_given?
          outcome = client_cancel_blocker(order.refresh, settled_now: settled)
        end

        outcome ||= cancel_unpaid_order(order)
        log_info('Client cancel request processed', order_id: order.id, outcome: outcome, status: order.status)
        outcome
      end

      # Why the client cannot (or no longer needs to) cancel the order
      #
      # @param order [Order] The order
      # @param settled_now [Boolean] Whether the payment (or a payment problem) was detected just now
      # @return [Symbol, nil] Outcome for #cancel_by_client, nil if the order can be cancelled
      def self.client_cancel_blocker(order, settled_now: false)
        case order.status
        when *CLIENT_CANCELLABLE then nil
        when OrderStatus::PAID then settled_now ? :paid_now : :already_paid
        when OrderStatus::IN_PROGRESS then :in_progress
        when OrderStatus::CANCELLED then :cancelled
        when OrderStatus::ERROR then settled_now ? :payment_problem : :not_cancellable
        else :not_cancellable
        end
      end
      private_class_method :client_cancel_blocker

      # Sync payment status right before cancelling; errors must not block the cancel
      #
      # @param order [Order] The order
      # @return [Hash] Sync result (empty if the sync failed)
      def self.last_chance_sync(order)
        sync_payment_status(order)
      rescue StandardError => e
        log_error('Last-chance payment sync failed, cancelling anyway', order_id: order.id, error: e.message)
        {}
      end
      private_class_method :last_chance_sync

      # Cancel an unpaid order: invoice at the provider first, then locally
      # A CANCELLED order with a still payable invoice (:cancelled_locally) is not lost:
      # StatusSyncer keeps polling it as a late-payment candidate.
      #
      # @param order [Order] NEW or INVOICE_CREATED order
      # @return [Symbol] Outcome for #cancel_by_client
      def self.cancel_unpaid_order(order)
        api_cancelled = false
        if order.invoice_id_provider
          api_cancelled = begin
            MWallet::Service.new.cancel_invoice_for_order(order)
          rescue StandardError => e
            log_error('Failed to cancel invoice via API', order_id: order.id, error: e.message)
            false
          end
        end

        # cancel_invoice_for_order already cancels locally (also when the API call fails with
        # an MWallet error); cover orders without invoice and unexpected errors the same way.
        # Conditional update, so it is a no-op if the order was cancelled or paid meanwhile.
        cancel_unpaid_locally(order)

        # Judge by the stored status, not by the API flag: the order may have been paid
        # (callback / StatusSyncer) while the cancel request was in flight
        if order.refresh.status == OrderStatus::CANCELLED
          (api_cancelled || order.invoice_id_provider.nil?) ? :cancelled : :cancelled_locally
        else
          client_cancel_blocker(order) || :not_cancellable
        end
      end
      private_class_method :cancel_unpaid_order

      # Atomically mark an unpaid order as cancelled (no-op if it was paid meanwhile)
      #
      # @param order [Order] The order
      # @return [Boolean] True if the row was updated
      def self.cancel_unpaid_locally(order)
        Order.where(id: order.id, status: CLIENT_CANCELLABLE)
             .update(status: OrderStatus::CANCELLED, updated_at: Time.now.utc)
             .positive?
      end
      private_class_method :cancel_unpaid_locally

      # Sync order status with payment provider
      # Also triggers notifications if payment was detected
      #
      # @param order [Order] Order to sync
      # @return [Hash] Result with :updated, :order_id, and :notify_barista flags
      def self.sync_payment_status(order)
        return { updated: false, order_id: nil, notify_barista: false } unless order.invoice_id_provider
        
        mwallet = MWallet::Service.new
        result = mwallet.sync_status(order)
        
        # Return the result (contains :updated, :order_id, :notify_barista)
        result
      end

      # Expire old invoices
      # NB: bulk variant without the last-chance payment check and client notification;
      # the bot uses Jobs::InvoiceExpirer instead.
      #
      # @param expire_minutes [Integer] Minutes before expiration
      # @return [Integer] Number of expired orders
      def self.expire_old_invoices(expire_minutes = nil)
        expire_minutes ||= CoffeeBot::Config::ORDER_EXPIRE_MINUTES
        
        cutoff_time = Time.now.utc - (expire_minutes * 60)
        
        # Use bulk update instead of N+1 queries
        # This updates all matching orders in a single SQL statement
        # ::DB is the connection (a bare DB here resolves to the CoffeeBot::DB class)
        count = ::DB.transaction do
          # Lock and update in bulk for consistency
          affected_ids = Order
            .for_update
            .where(status: OrderStatus::INVOICE_CREATED)
            .where(Sequel.lit('created_at < ?', cutoff_time))
            .select_map(:id)
          
          if affected_ids.empty?
            0
          else
            # Bulk update status; the status guard keeps a concurrent payment (PAID) intact
            # (for_update is a no-op on SQLite)
            expired = Order.where(id: affected_ids, status: OrderStatus::INVOICE_CREATED)
                           .update(status: OrderStatus::EXPIRED, updated_at: Time.now.utc)

            log_info('Orders expired', count: expired, candidate_ids: affected_ids)
            expired
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
