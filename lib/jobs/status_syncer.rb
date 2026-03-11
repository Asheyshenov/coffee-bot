# frozen_string_literal: true

# Status Syncer Job
# Periodically syncs order status with payment provider (fallback for callbacks)
# Polls every 2 seconds for faster payment confirmation

require_relative '../../config/boot'

module CoffeeBot
  module Jobs
    class StatusSyncer
      attr_reader :interval_seconds

      def initialize(interval_seconds: 2) # Default 2 seconds for faster payment confirmation
        @interval_seconds = interval_seconds
        @running = false
      end

      # Start the job loop
      def start
        return if @running

        @running = true
        log_info('StatusSyncer started', interval: @interval_seconds)

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
      def run_once
        # Find orders that need status sync
        orders = orders_to_sync

        return 0 if orders.empty?

        log_debug('Syncing order statuses', count: orders.length)

        synced_count = 0
        orders.each do |order|
          begin
            result = Services::OrderService.sync_payment_status(order)
            
            if result[:updated]
              synced_count += 1
              log_info('Order status synced', order_id: order.id, new_status: order.status)
              
              # Send notifications if payment was detected
              if result[:notify_barista] && result[:order_id]
                notify_baristas_async(result[:order_id])
                notify_client_async(result[:order_id])
              end
            end
          rescue StandardError => e
            log_error('Failed to sync order status', order_id: order.id, error: e.message)
          end
        end

        synced_count
      end

      private

      # Get orders that need status sync
      def orders_to_sync
        # Orders with INVOICE_CREATED status that haven't expired
        Order.where(status: OrderStatus::INVOICE_CREATED)
             .where(Sequel.lit('created_at > ?', Time.now.utc - (CoffeeBot::Config::ORDER_EXPIRE_MINUTES * 60)))
             .limit(50)
             .all
      end

      # Send notification to baristas asynchronously
      # Runs in a separate thread to not block the sync loop
      def notify_baristas_async(order_id)
        Thread.new do
          begin
            order = Order[order_id]
            unless order
              log_error('Cannot notify baristas: order not found', order_id: order_id)
              return
            end

            # Create bot instance for notification
            bot = Telegram::Bot::Client.new(CoffeeBot::Config::TELEGRAM_BOT_TOKEN)
            notifier = Services::Notifier.new(bot)

            # Notify baristas about new paid order
            notifier.notify_baristas_new_order(order)
            log_info('Baristas notified about paid order via polling', order_id: order_id)
          rescue StandardError => e
            log_error('Failed to notify baristas',
              order_id: order_id,
              error: e.message,
              backtrace: e.backtrace&.first(3)
            )
          end
        end
      end

      # Send notification to client asynchronously
      # Runs in a separate thread to not block the sync loop
      def notify_client_async(order_id)
        Thread.new do
          begin
            order = Order[order_id]
            unless order
              log_error('Cannot notify client: order not found', order_id: order_id)
              return
            end

            # Create bot instance for notification
            bot = Telegram::Bot::Client.new(CoffeeBot::Config::TELEGRAM_BOT_TOKEN)
            notifier = Services::Notifier.new(bot)

            # Notify client about successful payment
            notifier.notify_payment_received(order)
            log_info('Client notified about payment via polling', order_id: order_id)
          rescue StandardError => e
            log_error('Failed to notify client',
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
