# frozen_string_literal: true

# MWallet HTTP Client
# Low-level HTTP client for mwallet API

require 'faraday'
require 'json'
require_relative 'errors'
require_relative 'signer'

module MWallet
  class Client
    attr_reader :base_url, :sid, :version, :timeout, :retry_count

    # Initialize MWallet client
    def initialize(config)
      @base_url = config[:base_url] || CoffeeBot::Config::MWALLET_BASE_URL
      @sid = config[:sid] || CoffeeBot::Config::MWALLET_SID
      @password = config[:password] || CoffeeBot::Config::MWALLET_PASSWORD
      @version = config[:version] || CoffeeBot::Config::MWALLET_API_VERSION
      @timeout = config[:timeout] || CoffeeBot::Config::MWALLET_TIMEOUT_SECONDS
      @retry_count = config[:retry_count] || CoffeeBot::Config::MWALLET_RETRY_COUNT
      @test_mode = config[:test_mode] || CoffeeBot::Config::MWALLET_TEST_MODE

      @signer = Signer.new(@password)
    end

    # Create invoice
    def create_invoice(params)
      # Build data hash - compact to remove nil values
      data_hash = {
        'order_id' => params[:order_id],
        'desc' => params[:desc],
        'amount' => params[:amount],
        'currency' => params[:currency] || 'KGS',
        'test' => @test_mode ? 1 : nil,
        'long_term' => nil,
        'user_to' => params[:user_to],
        'date_life' => params[:date_life],
        'date_start_push' => nil,
        'count_push' => 1,
        'send_push' => 1,
        'send_sms' => nil,
        'success_url' => nil,
        'fail_url' => nil,
        'fields_other' => nil,
        'transtype' => nil,
        'result_url' => params[:result_url]
      }.compact

      # Build request params in exact order
      request_params = {
        'cmd' => 'createInvoice',
        'version' => @version,
        'sid' => @sid,
        'mktime' => Time.now.to_i.to_s,
        'lang' => 'ru',
        'data' => data_hash
      }

      log_request('createInvoice', request_params)

      # Sign and send (same approach as working raw request)
      json_for_sign = JSON.generate(request_params)
      hash = OpenSSL::HMAC.digest(OpenSSL::Digest.new('md5'), @password, json_for_sign).unpack1('H*')
      request_params['hash'] = hash

      response = with_retry do
        conn = Faraday.new(url: 'https://mw-api-test.dengi.kg') do |c|
          c.request :json
          c.response :json, content_type: /\bjson$/
          c.headers['Content-Type'] = 'application/json'
        end
        conn.post('/api/json/json.php', request_params)
      end

      handle_response(response, 'createInvoice')
    end

    # Get payment status
    def get_status(invoice_id)
      request_params = {
        'cmd' => 'statusPayment',
        'version' => @version,
        'sid' => @sid,
        'mktime' => Time.now.to_i.to_s,
        'lang' => 'ru',
        'data' => { 'invoice_id' => invoice_id }
      }

      log_request('statusPayment', request_params)

      json_for_sign = JSON.generate(request_params)
      hash = OpenSSL::HMAC.digest(OpenSSL::Digest.new('md5'), @password, json_for_sign).unpack1('H*')
      request_params['hash'] = hash

      response = with_retry do
        conn = Faraday.new(url: 'https://mw-api-test.dengi.kg') do |c|
          c.request :json
          c.response :json, content_type: /\bjson$/
          c.headers['Content-Type'] = 'application/json'
        end
        conn.post('/api/json/json.php', request_params)
      end

      handle_response(response, 'statusPayment')
    end

    # Verify callback signature
    def verify_callback_signature(params)
      @signer.verify_callback(params)
    end

    private

    # Execute request with retry
    def with_retry
      retries = 0
      begin
        yield
      rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
        retries += 1
        if retries <= @retry_count
          log_info("MWallet request failed, retrying (#{retries}/#{@retry_count})", error: e.message)
          sleep(2 ** retries)
          retry
        end
        raise MWalletError::ProviderTimeout.new("Request failed after #{@retry_count} retries: #{e.message}")
      rescue Faraday::Error => e
        raise MWalletError::NetworkError.new("Network error: #{e.message}")
      end
    end

    # Handle API response
    def handle_response(response, method_name)
      unless response.success?
        log_error("MWallet #{method_name} failed", status: response.status, body: response.body)
        raise MWalletError.classify_from_response(response)
      end

      body = response.body
      log_response(method_name, body)

      # Check for error in response body
      if body.is_a?(Hash) && body.dig('data', 'error')
        raise MWalletError::BusinessError.new(
          body.dig('data', 'desc') || 'Business error',
          code: body.dig('data', 'error'),
          details: body['data']
        )
      end

      body
    end

    # Log request (masking sensitive data)
    def log_request(method, params)
      masked = mask_sensitive(params)
      log_debug("MWallet request: #{method}", params: masked)
    end

    # Log response (masking sensitive data)
    def log_response(method, body)
      masked = mask_sensitive(body)
      log_debug("MWallet response: #{method}", response: masked)
    end

    # Mask sensitive fields for logging
    def mask_sensitive(data)
      return data unless data.is_a?(Hash)

      sensitive_fields = %w[password secret hash signature token]

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
