# frozen_string_literal: true

# Invoice Expirer Job
# Periodically expires old invoices that haven't been paid

require_relative '../../config/boot'

module CoffeeBot
  module Jobs
    class InvoiceExpirer
      attr_reader :interval_seconds, :expire_minutes

      def initialize(interval_seconds: 60, expire_minutes: nil)
        @interval_seconds = interval_seconds
        @expire_minutes = expire_minutes || CoffeeBot::Config::ORDER_EXPIRE_MINUTES
        @running = false
      end

      # Start the job loop
      def start
        return if @running

        @running = true
        log_info('InvoiceExpirer started', interval: @interval_seconds, expire_minutes: @expire_minutes)

        Thread.new do
          while @running
            begin
              run_once
            rescue StandardError => e
              log_error('InvoiceExpirer error', error: e.message)
            end

            sleep(@interval_seconds)
          end
        end
      end

      # Stop the job
      def stop
        @running = false
        log_info('InvoiceExpirer stopped')
      end

      # Run once (for manual execution or testing)
      def run_once
        expired_count = Services::OrderService.expire_old_invoices(@expire_minutes)

        if expired_count > 0
          log_info('Expired invoices', count: expired_count)

          # Notify clients about expired orders
          notify_expired_orders(expired_count)
        end

        expired_count
      end

      private

      # Notify clients about expired orders
      def notify_expired_orders(count)
        # Get recently expired orders that haven't been notified
        orders = Order.where(
          status: OrderStatus::EXPIRED,
          last_notified_status: nil
        ).where(
          updated_at: (Time.now.utc - 300)..Time.now.utc  # Last 5 minutes
        ).all

        orders.each do |order|
          begin
            # TODO: Send notification via bot
            # For now, just update the notified status
            order.update(last_notified_status: OrderStatus::EXPIRED)
            log_info('Notified client about expired order', order_id: order.id)
          rescue StandardError => e
            log_error('Failed to notify about expired order', order_id: order.id, error: e.message)
          end
        end
      end
    end
  end
end
