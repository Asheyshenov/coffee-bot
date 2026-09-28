# frozen_string_literal: true

# Invoice Expirer Job
# Periodically expires unpaid invoices older than ORDER_EXPIRE_MINUTES.
# Every overdue order is processed on its own:
#   1. last-chance payment check at MWallet (the client may have paid without a callback)
#   2. cancel the invoice at MWallet so it can no longer be paid
#   3. mark the order EXPIRED (skipped if its status changed concurrently)
#   4. tell the client that the payment time is over

require_relative '../../config/boot'
require 'telegram/bot'
require_relative '../services/notifier'
require_relative '../services/order_service'

module CoffeeBot
  module Jobs
    class InvoiceExpirer
      # Max orders handled per run (each costs up to two provider calls);
      # the rest is picked up by the next run
      BATCH_SIZE = 50

      attr_reader :interval_seconds, :expire_minutes

      # @param interval_seconds [Integer] Pause between runs
      # @param expire_minutes [Integer, nil] Invoice lifetime (default: ORDER_EXPIRE_MINUTES)
      # @param notifier [Services::Notifier, nil] Built lazily from TELEGRAM_BOT_TOKEN when nil
      def initialize(interval_seconds: 60, expire_minutes: nil, notifier: nil)
        @interval_seconds = interval_seconds
        @expire_minutes = expire_minutes || CoffeeBot::Config::ORDER_EXPIRE_MINUTES
        @notifier = notifier
        @running = false
      end

      # Start the job loop
      #
      # @return [Thread, nil] The job thread (nil if already running)
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
      #
      # @return [Integer] Number of orders marked as EXPIRED
      def run_once
        dataset = overdue_orders
        total = dataset.count
        return 0 if total.zero?

        orders = dataset.order(:created_at, :id).limit(BATCH_SIZE).all
        if total > orders.size
          log_info('InvoiceExpirer batch limit reached, the rest waits for the next run',
            batch: orders.size,
            deferred: total - orders.size
          )
        end

        expired_count = 0
        orders.each do |order|
          expired_count += 1 if expire_order(order)
        rescue StandardError => e
          # One broken order must not block the rest of the batch
          log_error('Failed to expire order', order_id: order.id, error: e.message)
        end

        log_info('Expired invoices', count: expired_count) if expired_count.positive?
        expired_count
      end

      private

      # INVOICE_CREATED orders older than the invoice lifetime
      def overdue_orders
        cutoff_time = Time.now.utc - (@expire_minutes * 60)

        Order.where(status: OrderStatus::INVOICE_CREATED)
             .where(Sequel.lit('created_at < ?', cutoff_time))
      end

      # Expire a single order
      #
      # @param order [Order] Overdue INVOICE_CREATED order
      # @return [Boolean] True if the order was marked as EXPIRED
      def expire_order(order)
        return false if payment_found_at_last_chance?(order)

        # The payment check may have closed the order already (provider cancelled the invoice)
        order.refresh
        unless order.status == OrderStatus::INVOICE_CREATED
          log_info('Skipping expiry: status changed during payment check', order_id: order.id, status: order.status)
          notify_client_expired(order, OrderStatus::CANCELLED) if closed_by_provider_unnotified?(order)
          return false
        end

        cancel_invoice_at_provider(order)

        # A callback may have changed the order while we were talking to the provider.
        # expire! is a conditional UPDATE (WHERE status = INVOICE_CREATED), so a payment
        # committed even after this re-read is never overwritten
        order.refresh
        unless order.expire!
          log_info('Skipping expiry: order status changed concurrently', order_id: order.id, status: order.status)
          return false
        end

        notify_client_expired(order, OrderStatus::EXPIRED)
        true
      end

      # Last-chance payment check before expiring
      #
      # @return [Boolean] True if a payment (or a payment problem) was found: expiry skipped
      def payment_found_at_last_chance?(order)
        result = begin
          Services::OrderService.sync_payment_status(order)
        rescue StandardError => e
          # Provider unreachable: expire anyway instead of keeping the order open forever
          log_error('Last-chance payment check failed, expiring anyway', order_id: order.id, error: e.message)
          return false
        end
        # Flags are set only for the caller that changed the order, so nothing is announced twice
        return false unless result && (result[:notify_barista] || result[:payment_error] || result[:refund_required])

        log_info('Payment found before expiry, skipping expiry',
          order_id: order.id,
          payment_error: result[:payment_error]
        )
        notify_payment(order, result)
        true
      end

      # Provider already closed the invoice and the payment check moved the order
      # to CANCELLED: nobody else tells the client about it
      def closed_by_provider_unnotified?(order)
        order.status == OrderStatus::CANCELLED && order.last_notified_status != OrderStatus::CANCELLED
      end

      # Cancel the invoice at MWallet so it cannot be paid after the order is expired.
      # Errors are only logged: the order is expired locally either way.
      # (cancel_invoice_for_order is not used: it sets CANCELLED instead of EXPIRED)
      def cancel_invoice_at_provider(order)
        return unless order.invoice_id_provider

        mwallet_service.client.cancel_invoice(order.invoice_id_provider)
        log_info('Cancelled expired invoice via API', order_id: order.id, invoice_id: order.invoice_id_provider)
      rescue StandardError => e
        log_error('Failed to cancel expired invoice via API', order_id: order.id, error: e.message)
      end

      # Payment found at the last moment: same notifications as StatusSyncer sends
      # (client + baristas when paid, baristas when the payment has a problem)
      def notify_payment(order, result)
        notifier.notify_payment_result(order, result)
      rescue StandardError => e
        log_error('Failed to send payment notifications', order_id: order.id, error: e.message)
      end

      # Tell the client that the payment time is over
      #
      # @param notified_status [String] Status recorded as last_notified_status
      def notify_client_expired(order, notified_status)
        if notifier.notify_invoice_expired(order)
          order.update(last_notified_status: notified_status)
          log_info('Notified client about expired order', order_id: order.id)
        else
          log_error('Failed to notify client about expired order', order_id: order.id)
        end
      rescue StandardError => e
        log_error('Failed to notify client about expired order', order_id: order.id, error: e.message)
      end

      def notifier
        @notifier ||= Services::Notifier.new(Telegram::Bot::Client.new(CoffeeBot::Config::TELEGRAM_BOT_TOKEN))
      end

      def mwallet_service
        @mwallet_service ||= MWallet::Service.new
      end
    end
  end
end
