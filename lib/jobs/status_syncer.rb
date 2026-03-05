# frozen_string_literal: true

# Status Syncer Job
# Periodically syncs order status with payment provider (fallback for callbacks)

require_relative '../../config/boot'

module CoffeeBot
  module Jobs
    class StatusSyncer
      attr_reader :interval_seconds

      def initialize(interval_seconds: 300) # Default 5 minutes
        @interval_seconds = interval_seconds
        @running = false
      end

      # Start the job loop
      def start
        return if @running

        @running = false
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

        log_info('Syncing order statuses', count: orders.length)

        synced_count = 0
        orders.each do |order|
          begin
            if Services::OrderService.sync_payment_status(order)
              synced_count += 1
              log_info('Order status synced', order_id: order.id, new_status: order.status)
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
             .where(Sequel.lit('updated_at < ?', Time.now.utc - 60)) # Not updated in last minute
             .limit(50)
             .all
      end
    end
  end
end
