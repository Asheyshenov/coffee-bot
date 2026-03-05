# frozen_string_literal: true

# QRPay Service
# High-level service for QRPay operations
# Handles business logic, idempotency, and error handling

require_relative 'qrpay_client'
require_relative 'status_mapper'
require_relative 'errors'

module QRPay
  class Service
    attr_reader :client

    def initialize(config = {})
      @client = Client.new(config)
    end

    # Create invoice for order
    # Implements idempotency - won't create duplicate invoices
    #
    # @param order [Order] The order to create invoice for
    # @return [Hash] Invoice data with qr_url, qr_payload, etc.
    # @raise [QRPayError::Base] On error
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
        merchant_invoice_id: order.merchant_invoice_id,
        amount: order.total_amount,
        currency: order.currency,
        description: "Заказ ##{order.id} - Coffee Bot",
        return_url: CoffeeBot::Config::PUBLIC_BASE_URL
      }

      response = client.create_invoice(params)

      # Extract invoice data from response
      invoice_data = extract_invoice_data(response)

      # Update order with invoice data
      order.set_invoice_data(invoice_data)
      order.transition_to!(OrderStatus::INVOICE_CREATED)

      log_info('Invoice created successfully', order_id: order.id, invoice_id: invoice_data[:invoice_id])

      invoice_data
    rescue QRPayError::Base => e
      log_error('Failed to create invoice', order_id: order.id, error: e.message)
      order.update(
        status: OrderStatus::ERROR,
        raw_create_response: { error: e.message, code: e.code }.to_json
      )
      raise
    end

    # Get invoice status from provider
    #
    # @param order [Order] The order to check
    # @return [Hash] Status data
    def get_invoice_status(order)
      response = client.get_invoice_status(order.merchant_invoice_id)

      # Map status to internal format
      provider_status = response['status'] || response[:status]
      internal_status = StatusMapper.map_from_provider(provider_status)

      {
        provider_status: provider_status,
        internal_status: internal_status,
        paid_amount: response['paidAmount'] || response[:paidAmount],
        paid_at: parse_datetime(response['paidAt'] || response[:paidAt]),
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

      status_data = get_invoice_status(order)

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
            paid_at: status_data[:paid_at]
          )
          return true
        end
      when :expired
        if order.status == OrderStatus::INVOICE_CREATED
          order.expire!
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

    # Cancel invoice
    # Only works for pending invoices
    #
    # @param order [Order] The order to cancel
    # @param reason [String] Optional cancellation reason
    # @return [Boolean] True if cancelled
    # @raise [QRPayError::Base] On error
    def cancel_invoice(order, reason = nil)
      # First sync status to ensure we have latest state
      sync_status(order)

      # Check if already paid
      if order.status == OrderStatus::PAID
        raise QRPayError::InvoiceAlreadyPaidError.new('Cannot cancel paid invoice')
      end

      # Check if cancellable
      unless [OrderStatus::INVOICE_CREATED, OrderStatus::NEW].include?(order.status)
        raise QRPayError::InvoiceNotCancellableError.new("Cannot cancel invoice in status #{order.status}")
      end

      # If already cancelled, return success (idempotency)
      if order.status == OrderStatus::CANCELLED
        log_info('Invoice already cancelled', order_id: order.id)
        return true
      end

      # Call API to cancel
      response = client.cancel_invoice(order.merchant_invoice_id, reason)

      # Update order status
      order.update(status: OrderStatus::CANCELLED)

      log_info('Invoice cancelled', order_id: order.id)

      true
    end

    # Process partial refund
    #
    # @param order [Order] The order to refund
    # @param amount [Integer] Amount to refund in tyiyn
    # @param reason [String] Optional refund reason
    # @return [PaymentOperation] The created payment operation
    # @raise [QRPayError::Base] On error
    def refund_partial(order, amount, reason = nil)
      # Validate refund amount
      payment = order.payment
      unless payment
        raise QRPayError::BusinessError.new('No payment found for order')
      end

      unless payment.can_refund?(amount)
        raise QRPayError::RefundLimitExceededError.new(
          "Cannot refund #{amount}. Maximum refundable: #{payment.remaining_refundable}"
        )
      end

      # Create payment operation record
      operation = PaymentOperation.create(
        order_id: order.id,
        operation_type: PaymentOperationType::REFUND,
        amount: amount,
        reason: reason,
        status: PaymentOperationStatus::PENDING
      )

      begin
        response = client.refund_partial(order.merchant_invoice_id, amount, reason)

        operation.complete!(response['operationId'] || response[:operationId])
        payment.update_refund_status!

        log_info('Refund completed', order_id: order.id, amount: amount, operation_id: operation.id)

        operation
      rescue QRPayError::Base => e
        operation.fail!(e.message)
        raise
      end
    end

    # Void payment
    #
    # @param order [Order] The order to void
    # @param reason [String] Optional void reason
    # @return [PaymentOperation] The created payment operation
    # @raise [QRPayError::Base] On error
    def void_payment(order, reason = nil)
      payment = order.payment
      unless payment && payment.status == PaymentStatus::PAID
        raise QRPayError::BusinessError.new('No paid payment found for order')
      end

      # Create payment operation record
      operation = PaymentOperation.create(
        order_id: order.id,
        operation_type: PaymentOperationType::VOID,
        amount: payment.paid_amount,
        reason: reason,
        status: PaymentOperationStatus::PENDING
      )

      begin
        response = client.void_payment(order.merchant_invoice_id, reason)

        operation.complete!(response['operationId'] || response[:operationId])
        payment.update(status: PaymentStatus::VOIDED)

        log_info('Payment voided', order_id: order.id, operation_id: operation.id)

        operation
      rescue QRPayError::Base => e
        operation.fail!(e.message)
        raise
      end
    end

    # Download transaction history CSV
    #
    # @param date_from [Date] Start date
    # @param date_to [Date] End date
    # @param filters [Hash] Optional filters
    # @return [Report] The created report record
    def get_history_csv(date_from, date_to, filters = {})
      # Check if report already exists
      existing = Report.for_date_range(date_from, date_to)
      if existing && existing.file_exists?
        log_info('Report already exists', from: date_from, to: date_to)
        return existing
      end

      # Download CSV
      csv_content = client.get_history_csv(date_from, date_to, filters)

      # Save to file
      file_name = "transactions_#{date_from}_#{date_to}.csv"
      file_path = File.join('data', 'reports', file_name)
      
      FileUtils.mkdir_p(File.dirname(file_path))
      File.write(file_path, csv_content)

      # Create report record
      report = Report.create_report(
        date_from: date_from,
        date_to: date_to,
        filters: filters,
        file_path: file_path,
        checksum: Digest::MD5.hexdigest(csv_content)
      )

      log_info('Report downloaded', report_id: report.id, file: file_path)

      report
    end

    # Process callback from QRPay
    #
    # @param params [Hash] Callback parameters
    # @param raw_body [String] Raw request body
    # @param signature [String] Request signature
    # @return [Boolean] True if processed successfully
    def process_callback(params, raw_body, signature)
      # Log callback (outside transaction - logging is independent)
      callback_log = CallbackLog.log_callback(
        event_id: params['eventId'] || params[:eventId],
        invoice_id: params['invoiceId'] || params[:invoiceId],
        merchant_invoice_id: params['merchantInvoiceId'] || params[:merchantInvoiceId],
        raw_body: raw_body,
        verified: false
      )

      # Verify signature (outside transaction - no DB changes)
      unless client.verify_callback_signature(params, signature)
        callback_log.update(verified_signature: false)
        log_error('Callback signature verification failed', invoice_id: params['invoiceId'])
        raise QRPayError::SignatureError.new('Invalid signature')
      end

      callback_log.mark_verified!

      # Wrap all database operations in a transaction for consistency
      DB.transaction do
        # Check for duplicate (with row-level lock to prevent concurrent processing)
        if CallbackLog.duplicate?(params['eventId'], params['invoiceId'], raw_body)
          log_info('Duplicate callback detected, skipping', event_id: params['eventId'])
          callback_log.mark_processed!
          return true
        end

        # Find order by merchant invoice ID (with lock for update)
        merchant_invoice_id = params['merchantInvoiceId'] || params[:merchantInvoiceId]
        order = Order.for_update.where(merchant_invoice_id: merchant_invoice_id).first

        unless order
          log_error('Order not found for callback', merchant_invoice_id: merchant_invoice_id)
          callback_log.mark_failed!('Order not found')
          return true # Return true to acknowledge receipt
        end

        # Process payment status
        provider_status = params['status'] || params[:status]
        internal_status = StatusMapper.map_from_provider(provider_status)

        if internal_status == :paid && order.status == OrderStatus::INVOICE_CREATED
          order.mark_paid!(
            paid_amount: params['amount'] || params[:amount],
            paid_at: parse_datetime(params['paidAt'] || params[:paidAt])
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
      {
        invoice_id: response['invoiceId'] || response[:invoiceId],
        qr_payload: response['qrPayload'] || response[:qrPayload],
        qr_url: response['qrUrl'] || response[:qrUrl],
        qr_image_base64: response['qrImageBase64'] || response[:qrImageBase64],
        expires_at: parse_datetime(response['expiresAt'] || response[:expiresAt]),
        raw_response: response.to_json
      }
    end

    # Get existing invoice data from order
    def existing_invoice_data(order)
      {
        invoice_id: order.invoice_id_provider,
        qr_payload: order.qr_payload,
        qr_url: order.qr_url,
        qr_image_base64: order.qr_image_base64,
        expires_at: order.expires_at,
        raw_response: order.raw_create_response
      }
    end

    # Parse datetime string
    def parse_datetime(value)
      return nil if value.nil?
      Time.parse(value.to_s).utc
    rescue ArgumentError
      nil
    end
  end
end
