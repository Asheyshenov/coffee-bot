# frozen_string_literal: true

# QRPay HTTP Client
# Low-level HTTP client for O!Деньги QRPay API

require 'faraday'
require 'json'
require_relative 'errors'
require_relative 'signer'

module QRPay
  class Client
    attr_reader :base_url, :merchant_id, :timeout, :retry_count

    # Initialize QRPay client
    #
    # @param config [Hash] Configuration options
    # @option config [String] :base_url API base URL
    # @option config [String] :merchant_id Merchant ID
    # @option config [String] :secret_key Secret key for signing
    # @option config [Integer] :timeout Request timeout in seconds
    # @option config [Integer] :retry_count Number of retries
    def initialize(config)
      @base_url = config[:base_url] || CoffeeBot::Config::QRPAY_BASE_URL
      @merchant_id = config[:merchant_id] || CoffeeBot::Config::QRPAY_MERCHANT_ID
      @secret_key = config[:secret_key] || CoffeeBot::Config::QRPAY_SECRET_KEY
      @timeout = config[:timeout] || CoffeeBot::Config::QRPAY_TIMEOUT_SECONDS
      @retry_count = config[:retry_count] || CoffeeBot::Config::QRPAY_RETRY_COUNT
      
      @signature_builder = SignatureBuilder.new(@secret_key)
      @connection = build_connection
    end

    # Create invoice
    #
    # @param params [Hash] Invoice parameters
    # @return [Hash] Response with invoice data
    # @raise [QRPayError::Base] On error
    def create_invoice(params)
      payload = build_invoice_payload(params)
      
      log_request('createInvoice', payload)
      
      response = with_retry do
        @connection.post('/api/v1/invoice/create') do |req|
          req.body = payload.to_json
        end
      end
      
      handle_response(response, 'createInvoice')
    end

    # Get invoice status
    #
    # @param merchant_invoice_id [String] Merchant invoice ID
    # @return [Hash] Response with status data
    # @raise [QRPayError::Base] On error
    def get_invoice_status(merchant_invoice_id)
      payload = {
        merchantId: @merchant_id,
        merchantInvoiceId: merchant_invoice_id
      }
      
      log_request('getInvoiceStatus', payload)
      
      response = with_retry do
        @connection.get('/api/v1/invoice/status') do |req|
          req.params = payload
        end
      end
      
      handle_response(response, 'getInvoiceStatus')
    end

    # Cancel invoice
    #
    # @param merchant_invoice_id [String] Merchant invoice ID
    # @param reason [String] Optional cancellation reason
    # @return [Hash] Response
    # @raise [QRPayError::Base] On error
    def cancel_invoice(merchant_invoice_id, reason = nil)
      payload = {
        merchantId: @merchant_id,
        merchantInvoiceId: merchant_invoice_id,
        reason: reason
      }.compact
      
      log_request('cancelInvoice', payload)
      
      response = with_retry do
        @connection.post('/api/v1/invoice/cancel') do |req|
          req.body = payload.to_json
        end
      end
      
      handle_response(response, 'cancelInvoice')
    end

    # Partial refund
    #
    # @param merchant_invoice_id [String] Merchant invoice ID
    # @param amount [Integer] Refund amount in tyiyn
    # @param reason [String] Optional refund reason
    # @return [Hash] Response
    # @raise [QRPayError::Base] On error
    def refund_partial(merchant_invoice_id, amount, reason = nil)
      payload = {
        merchantId: @merchant_id,
        merchantInvoiceId: merchant_invoice_id,
        amount: amount,
        reason: reason
      }.compact
      
      log_request('refundPartial', payload)
      
      response = with_retry do
        @connection.post('/api/v1/invoice/refund') do |req|
          req.body = payload.to_json
        end
      end
      
      handle_response(response, 'refundPartial')
    end

    # Void payment
    #
    # @param merchant_invoice_id [String] Merchant invoice ID
    # @param reason [String] Optional void reason
    # @return [Hash] Response
    # @raise [QRPayError::Base] On error
    def void_payment(merchant_invoice_id, reason = nil)
      payload = {
        merchantId: @merchant_id,
        merchantInvoiceId: merchant_invoice_id,
        reason: reason
      }.compact
      
      log_request('voidPayment', payload)
      
      response = with_retry do
        @connection.post('/api/v1/invoice/void') do |req|
          req.body = payload.to_json
        end
      end
      
      handle_response(response, 'voidPayment')
    end

    # Get transaction history CSV
    #
    # @param date_from [Date] Start date
    # @param date_to [Date] End date
    # @param filters [Hash] Optional filters
    # @return [String] CSV content
    # @raise [QRPayError::Base] On error
    def get_history_csv(date_from, date_to, filters = {})
      params = {
        merchantId: @merchant_id,
        dateFrom: date_from.iso8601,
        dateTo: date_to.iso8601,
        **filters
      }
      
      log_request('getHistoryCsv', params)
      
      response = with_retry do
        @connection.get('/api/v1/reports/transactions.csv') do |req|
          req.params = params
        end
      end
      
      if response.success?
        response.body
      else
        raise QRPayError.classify_from_response(response)
      end
    end

    # Verify callback signature
    #
    # @param params [Hash] Callback parameters
    # @param signature [String] Signature from callback
    # @return [Boolean] True if valid
    def verify_callback_signature(params, signature)
      @signature_builder.verify_callback(params, signature)
    end

    private

    # Build Faraday connection
    def build_connection
      Faraday.new(url: @base_url) do |conn|
        conn.request :json
        conn.response :json, content_type: /\bjson$/
        conn.options.timeout = @timeout
        conn.options.open_timeout = @timeout
        conn.headers['Content-Type'] = 'application/json'
        conn.headers['Accept'] = 'application/json'
        conn.headers['User-Agent'] = "CoffeeBot/#{CoffeeBot::Config::RACK_ENV}"
      end
    end

    # Build invoice payload with required fields
    def build_invoice_payload(params)
      {
        merchantId: @merchant_id,
        merchantInvoiceId: params[:merchant_invoice_id],
        amount: params[:amount],
        currency: params[:currency] || 'KGS',
        description: params[:description],
        returnUrl: params[:return_url],
        resultUrl: CoffeeBot::Config::QRPAY_CALLBACK_URL,
        expiresIn: params[:expires_in] || CoffeeBot::Config::ORDER_EXPIRE_MINUTES * 60
      }
    end

    # Execute request with retry
    def with_retry
      retries = 0
      begin
        yield
      rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
        retries += 1
        if retries <= @retry_count
          log_info("QRPay request failed, retrying (#{retries}/#{@retry_count})", error: e.message)
          sleep(2 ** retries) # Exponential backoff
          retry
        end
        raise QRPayError::ProviderTimeout.new("Request failed after #{@retry_count} retries: #{e.message}")
      rescue Faraday::Error => e
        raise QRPayError::NetworkError.new("Network error: #{e.message}")
      end
    end

    # Handle API response
    def handle_response(response, method_name)
      unless response.success?
        log_error("QRPay #{method_name} failed", status: response.status, body: response.body)
        raise QRPayError.classify_from_response(response)
      end
      
      body = response.body
      log_response(method_name, body)
      
      # Check for error in response body
      if body.is_a?(Hash) && body['error']
        raise QRPayError::BusinessError.new(
          body['error']['message'] || 'Business error',
          code: body['error']['code'],
          details: body['error']
        )
      end
      
      body
    end

    # Log request (masking sensitive data)
    def log_request(method, params)
      masked = mask_sensitive(params)
      log_debug("QRPay request: #{method}", params: masked)
    end

    # Log response (masking sensitive data)
    def log_response(method, body)
      masked = mask_sensitive(body)
      log_debug("QRPay response: #{method}", response: masked)
    end

    # Mask sensitive fields for logging
    def mask_sensitive(data)
      return data unless data.is_a?(Hash)
      
      sensitive_fields = %w[secretKey secret signature password token]
      
      data.transform_keys(&:to_s).each_with_object({}) do |(k, v), result|
        if sensitive_fields.any? { |f| k.downcase.include?(f.downcase) }
          result[k] = '***MASKED***'
        elsif v.is_a?(Hash)
          result[k] = mask_sensitive(v)
        else
          result[k] = v
        end
      end
    end
  end
end
