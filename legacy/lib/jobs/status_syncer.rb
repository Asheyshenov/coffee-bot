# frozen_string_literal: true

# Status Syncer Job
# Periodically syncs order status with payment provider (fallback for callbacks)
# Polls every 2 seconds for faster payment confirmation.
# Less often (every 60 seconds) it also looks for late payments: money that
# arrived after the order had already EXPIRED or been CANCELLED.

require_relative '../../config/boot'

module CoffeeBot
  module Jobs
    class StatusSyncer
      # Late payments are looked for within this window after the order's last update
      LATE_PAYMENT_WINDOW_SECONDS = 24 * 60 * 60
      # Max late-payment candidates checked per run
      LATE_PAYMENT_BATCH = 20

      attr_reader :interval_seconds, :late_payment_interval_seconds

      def initialize(interval_seconds: 2, late_payment_interval_seconds: 60) # Default 2 seconds for faster payment confirmation
        @interval_seconds = interval_seconds
        @late_payment_interval_seconds = late_payment_interval_seconds
        @last_late_payment_check_at = nil
        # Id of the last late-payment candidate checked (round-robin cursor)
        @late_payment_cursor = 0
        @running = false
      end

      # Start the job loop
      def start
        return if @running

        @running = true
        log_info('StatusSyncer started', interval: @interval_seconds, late_payment_interval: @late_payment_interval_seconds)

        Thread.new do
          while @running
            begin
              run_once
            rescue StandardError => e
              log_error('StatusSyncer error', error: e.message)
            end

            sleep(@interval_seconds)
          end
        end
      end

      # Stop the job
      def stop
        @running = false
        log_info('StatusSyncer stopped')
      end

      # Run once (for manual execution or testing)
      # Late-payment candidates are included only when their (slower) interval is due.
      #
      # @return [Integer] Number of orders whose status changed
      def run_once
        synced_count = sync_orders(orders_to_sync)

        if late_payment_check_due?
          @last_late_payment_check_at = monotonic_now
          synced_count += sync_orders(late_payment_candidates, stop_on_provider_error: true) do |order|
            @late_payment_cursor = order.id
          end
        end

        synced_count
      end

      private

      # Sync a batch of orders and send notifications for the ones that changed
      #
      # @param stop_on_provider_error [Boolean] Skip the rest of the batch when the provider
      #   is unreachable (late-payment checks must not block the loop for the whole batch)
      # @yieldparam order [Order] Called right before each order is checked
      def sync_orders(orders, stop_on_provider_error: false)
        return 0 if orders.empty?

        log_debug('Syncing order statuses', count: orders.length)

        synced_count = 0
        orders.each do |order|
          yield order if block_given?

          begin
            result = Services::OrderService.sync_payment_status(order)

            if result[:updated]
              synced_count += 1
              log_info('Order status synced', order_id: order.id, new_status: order.status)

              # Only the caller that changed the order gets these flags,
              # so a payment detected by both callback and polling is announced once
              if result[:order_id] && (result[:notify_barista] || result[:payment_error] || result[:refund_required])
                notify_payment_async(result)
              end
            end
          rescue MWalletError::NetworkError, MWalletError::ProviderTimeout => e
            log_error('Failed to sync order status', order_id: order.id, error: e.message)
            if stop_on_provider_error
              log_info('Provider unreachable, remaining late-payment checks postponed', order_id: order.id)
              break
            end
          rescue StandardError => e
            log_error('Failed to sync order status', order_id: order.id, error: e.message)
          end
        end

        synced_count
      end

      # Get orders that need status sync
      def orders_to_sync
        # Orders with INVOICE_CREATED status that haven't expired
        Order.where(status: OrderStatus::INVOICE_CREATED)
             .where(Sequel.lit('created_at > ?', Time.now.utc - (CoffeeBot::Config::ORDER_EXPIRE_MINUTES * 60)))
             .limit(50)
             .all
      end

      # EXPIRED/CANCELLED orders with an invoice, updated recently and with no
      # settled payment: the customer may still have paid (late payment)
      #
      # Round-robin over the whole window: each run continues after the last checked
      # order and wraps around. A failed check does not change the order, so always
      # taking the newest LATE_PAYMENT_BATCH would never reach the others.
      def late_payment_candidates
        settled_payment = Payment.where(
          Sequel[:payments][:order_id] => Sequel[:orders][:id],
          Sequel[:payments][:status] => PaymentStatus::SETTLED
        )

        candidates = Order.where(status: OrderStatus::LATE_PAYMENT)
                          .exclude(invoice_id_provider: nil)
                          .where(Sequel.lit('orders.updated_at > ?', Time.now.utc - LATE_PAYMENT_WINDOW_SECONDS))
                          .exclude(settled_payment.exists)
                          .order(Sequel[:orders][:id])

        batch = candidates.where(Sequel[:orders][:id] > @late_payment_cursor).limit(LATE_PAYMENT_BATCH).all
        if batch.size < LATE_PAYMENT_BATCH && @late_payment_cursor.positive?
          batch += candidates.where(Sequel[:orders][:id] <= @late_payment_cursor)
                             .limit(LATE_PAYMENT_BATCH - batch.size)
                             .all
        end
        batch
      end

      def late_payment_check_due?
        @last_late_payment_check_at.nil? ||
          monotonic_now - @last_late_payment_check_at >= @late_payment_interval_seconds
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # Send payment notifications asynchronously (client + baristas, or a payment
      # problem alert). Runs in a separate thread to not block the sync loop.
      #
      # @param result [Hash] Result of MWallet::Service#sync_status
      def notify_payment_async(result)
        order_id = result[:order_id]

        Thread.new do
          begin
            order = Order[order_id]
            unless order
              log_error('Cannot send payment notifications: order not found', order_id: order_id)
              next
            end

            # Create bot instance for notification
            bot = Telegram::Bot::Client.new(CoffeeBot::Config::TELEGRAM_BOT_TOKEN)
            notifier = Services::Notifier.new(bot)

            notifier.notify_payment_result(order, result)
            log_info('Payment notifications sent via polling', order_id: order_id,
              refund_required: result[:refund_required] || false, payment_error: result[:payment_error])
          rescue StandardError => e
            log_error('Failed to send payment notifications',
              order_id: order_id,
              error: e.message,
              backtrace: e.backtrace&.first(3)
            )
          end
        end
      end
    end
  end
end
