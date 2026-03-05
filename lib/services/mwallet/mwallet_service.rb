# frozen_string_literal: true

# MWallet Service
# High-level service for mwallet operations
# Handles business logic, idempotency, and error handling

require_relative 'mwallet_client'
require_relative 'status_mapper'
require_relative 'errors'

module MWallet
  class Service
    attr_reader :client

    def initialize(config = {})
      @client = Client.new(config)
    end

    # Create invoice for order
    # Implements idempotency - won't create duplicate invoices
    #
    # @param order [Order] The order to create invoice for
    # @return [Hash] Invoice data with paylink_url, qr_url, etc.
    # @raise [MWalletError::Base] On error
    def create_invoice_for_order(order)
      # Check idempotency - if invoice already exists and is valid, return it
      if order.invoice_id_provider && order.status == OrderStatus::INVOICE_CREATED
        if !order.invoice_expired?
          log_info('Invoice already exists, returning existing', order_id: order.id)
          return existing_invoice_data(order)
        end
      end

      # Create new invoice
      params = {
        order_id: order.merchant_invoice_id,
        desc: "Заказ ##{order.id} - Coffee Bot",
        amount: order.total_amount,
        currency: order.currency || 'KGS',
        result_url: CoffeeBot::Config::MWALLET_CALLBACK_URL,
        date_life: CoffeeBot::Config::ORDER_EXPIRE_MINUTES * 60
      }

      response = client.create_invoice(params)

      # Extract invoice data from response
      invoice_data = extract_invoice_data(response)

      # Update order with invoice data
      order.set_invoice_data(invoice_data)
      order.transition_to!(OrderStatus::INVOICE_CREATED)

      log_info('Invoice created successfully', order_id: order.id, invoice_id: invoice_data[:invoice_id])

      invoice_data
    rescue MWalletError::Base => e
      log_error('Failed to create invoice', order_id: order.id, error: e.message)
      order.update(
        status: OrderStatus::ERROR,
        raw_create_response: { error: e.message, code: e.code }.to_json
      )
      raise
    end

    # Get payment status from provider
    #
    # @param order [Order] The order to check
    # @return [Hash] Status data
    def get_payment_status(order)
      response = client.get_status(order.invoice_id_provider)

      # Map status to internal format
      provider_status = response.dig('data', 'status') || response.dig(:data, :status)
      internal_status = StatusMapper.map_from_provider(provider_status)

      {
        provider_status: provider_status,
        internal_status: internal_status,
        paid_amount: response.dig('data', 'amount') || response.dig(:data, :amount),
        raw_response: response
      }
    end

    # Sync order status with provider
    # Updates order and payment records based on current provider status
    #
    # @param order [Order] The order to sync
    # @return [Boolean] True if status was updated
    def sync_status(order)
      return false unless order.invoice_id_provider

      status_data = get_payment_status(order)

      log_info('Syncing order status',
        order_id: order.id,
        provider_status: status_data[:provider_status],
        internal_status: status_data[:internal_status]
      )

      case status_data[:internal_status]
      when :paid
        if order.status == OrderStatus::INVOICE_CREATED
          order.mark_paid!(
            paid_amount: status_data[:paid_amount],
            paid_at: Time.now.utc
          )
          return true
        end
      when :cancelled
        if [OrderStatus::INVOICE_CREATED, OrderStatus::PAID].include?(order.status)
          order.update(status: OrderStatus::CANCELLED)
          return true
        end
      end

      false
    end

    # Process callback from mwallet
    #
    # @param params [Hash] Callback parameters
    # @param raw_body [String] Raw request body
    # @return [Boolean] True if processed successfully
    def process_callback(params, raw_body)
      # Log callback
      callback_log = CallbackLog.log_callback(
        event_id: params['invoice_id'] || params[:invoice_id],
        invoice_id: params['invoice_id'] || params[:invoice_id],
        merchant_invoice_id: params['order_id'] || params[:order_id],
        raw_body: raw_body,
        verified: false
      )

      # Verify signature
      unless client.verify_callback_signature(params)
        callback_log.update(verified_signature: false)
        log_error('Callback signature verification failed', invoice_id: params['invoice_id'])
        raise MWalletError::SignatureError.new('Invalid signature')
      end

      callback_log.mark_verified!

      # Wrap all database operations in a transaction
      DB.transaction do
        # Check for duplicate
        if CallbackLog.duplicate?(params['invoice_id'], params['invoice_id'], raw_body)
          log_info('Duplicate callback detected, skipping', invoice_id: params['invoice_id'])
          callback_log.mark_processed!
          return true
        end

        # Find order by invoice ID
        invoice_id = params['invoice_id'] || params[:invoice_id]
        order = Order.for_update.where(invoice_id_provider: invoice_id).first

        unless order
          log_error('Order not found for callback', invoice_id: invoice_id)
          callback_log.mark_failed!('Order not found')
          return true # Return true to acknowledge receipt
        end

        # Process payment status
        provider_status = params['status'] || params[:status]
        internal_status = StatusMapper.map_from_provider(provider_status)

        if internal_status == :paid && order.status == OrderStatus::INVOICE_CREATED
          order.mark_paid!(
            paid_amount: params['amount'] || params[:amount],
            paid_at: Time.now.utc
          )
          log_info('Order marked as paid via callback', order_id: order.id)
        end

        callback_log.mark_processed!
        true
      end
    end

    private

    # Extract invoice data from API response
    def extract_invoice_data(response)
      data = response['data'] || response[:data] || {}
      
      {
        invoice_id: data['invoice_id'] || data[:invoice_id],
        qr_url: data['qr_url'] || data[:qr_url],
        paylink_url: data['paylink_url'] || data[:paylink_url],
        emv_qr_url: data['emv_qr'] || data[:emv_qr],  # URL to QR image
        qr_image_base64: data['emv_qr_img'] || data[:emv_qr_img],
        emv_qr_data: data['emv_qr_data'] || data[:emv_qr_data],
        raw_response: response.to_json
      }
    end

    # Get existing invoice data from order
    def existing_invoice_data(order)
      {
        invoice_id: order.invoice_id_provider,
        qr_url: order.qr_url,
        paylink_url: order.qr_url, # Using qr_url field for paylink
        emv_qr_url: order.emv_qr_url,
        qr_image_base64: order.qr_image_base64,
        raw_response: order.raw_create_response
      }
    end
  end
end
