# frozen_string_literal: true

require "faraday"
require "json"

module MWallet
  # Low-level HTTP client of the O!Dengi MWallet JSON API (one merchant account).
  # Every request is a signed JSON document POSTed to the same endpoint.
  #
  #   MWallet::Client.new(base_url: "https://mw-api-test.dengi.kg/api/json/json.php",
  #                       sid: "5050", password: "...", version: 1005, test_mode: true)
  class Client
    DEFAULT_PATH = "/api/json/json.php"
    SENSITIVE_FIELDS = %w[password secret hash signature token].freeze

    attr_reader :base_url, :sid, :version, :timeout, :retry_count, :test_mode

    # @param base_url [String] full endpoint URL (a bare host gets DEFAULT_PATH)
    # @param timeout [Integer] open/read timeout in seconds
    # @param retry_count [Integer] retries on timeouts / connection failures
    def initialize(base_url:, sid:, password:, version: 1005, test_mode: false, timeout: 30, retry_count: 3)
      @base_url = base_url
      @sid = sid
      @version = version
      @test_mode = test_mode
      @timeout = timeout
      @retry_count = retry_count
      @signer = Signer.new(password)
      @path = endpoint_path(base_url)
      @connection = build_connection
    end

    # @param params [Hash] :order_id, :desc, :amount (tyiyn), :currency, :user_to, :date_life (s), :result_url
    # @return [Hash] provider response
    def create_invoice(params)
      request("createInvoice", build_invoice_data(params))
    end

    # @return [Hash] provider response, e.g. {"data" => {"status" => "processing"}}
    def get_status(invoice_id)
      request("statusPayment", { "invoice_id" => invoice_id })
    end

    # The command is case-sensitive: "InvoiceCancel" -> "Команда не определена"
    #
    # @return [Hash] provider response, e.g. {"data" => {"success" => true}}
    def cancel_invoice(invoice_id)
      request("invoiceCancel", { "invoice_id" => invoice_id })
    end

    def verify_callback_signature(params)
      @signer.verify_callback(params)
    end

    private

    def request(cmd, data)
      params = {
        "cmd" => cmd,
        "version" => version,
        "sid" => sid,
        "mktime" => Time.now.to_i.to_s,
        "lang" => "ru",
        "data" => data
      }
      log_debug("MWallet request", cmd: cmd, params: mask_sensitive(params).to_json)

      signed = @signer.build_signed_request(params)
      response = with_retry { @connection.post(@path, signed) }
      handle_response(response, cmd)
    end

    def endpoint_path(url)
      path = URI.parse(url.to_s).path
      path.blank? || path == "/" ? DEFAULT_PATH : path
    rescue URI::InvalidURIError
      DEFAULT_PATH
    end

    def build_connection
      Faraday.new(url: base_url) do |c|
        c.request :json
        c.response :json, content_type: /\bjson\z/
        c.headers["Content-Type"] = "application/json"
        c.options.timeout = timeout
        c.options.open_timeout = timeout
      end
    end

    def build_invoice_data(params)
      {
        "order_id" => params[:order_id],
        "desc" => params[:desc],
        "amount" => params[:amount],
        "currency" => params[:currency] || "KGS",
        "test" => test_mode ? 1 : nil,
        "long_term" => nil,
        "user_to" => params[:user_to],
        "date_life" => params[:date_life],
        "date_start_push" => nil,
        "count_push" => 1,
        "send_push" => 1,
        "send_sms" => nil,
        "success_url" => nil,
        "fail_url" => nil,
        "fields_other" => nil,
        "transtype" => nil,
        "result_url" => params[:result_url]
      }.compact
    end

    def with_retry
      retries = 0
      begin
        yield
      rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
        retries += 1
        if retries <= retry_count
          AppLog.warn("MWallet request failed, retrying", attempt: retries, of: retry_count, error: e.class.name)
          sleep(2**retries)
          retry
        end
        raise MWalletError::ProviderTimeout, "Request failed after #{retry_count} retries: #{e.message}"
      rescue Faraday::Error => e
        raise MWalletError::NetworkError, "Network error: #{e.message}"
      end
    end

    def handle_response(response, cmd)
      unless response.success?
        AppLog.error("MWallet request failed", cmd: cmd, http_status: response.status)
        raise MWalletError.classify_from_response(response)
      end

      body = parse_body(response.body)
      log_debug("MWallet response", cmd: cmd, response: mask_sensitive(body).to_json)

      # The error sits at the top level ({"error":2,"desc":"Команда не определена"})
      # or inside data, depending on the command
      error_source = [ body, body["data"] ].find { |part| part.is_a?(Hash) && provider_error?(part["error"]) }
      if error_source
        raise MWalletError::BusinessError.new(error_source["desc"].presence || "Business error",
                                              code: error_source["error"], details: error_source)
      end

      body
    end

    # A body that Faraday did not parse (unexpected content type) is parsed here
    def parse_body(body)
      return body if body.is_a?(Hash)

      parsed = body.is_a?(String) && body.present? ? JSON.parse(body) : nil
      raise MWalletError::BusinessError, "Unexpected MWallet response" unless parsed.is_a?(Hash)

      parsed
    rescue JSON::ParserError
      raise MWalletError::BusinessError, "Unexpected MWallet response"
    end

    # "error": 0 / "0" / false / "" means no error
    def provider_error?(value)
      !(value.nil? || value == false || value.to_s.strip.empty? || value.to_s.strip == "0")
    end

    def mask_sensitive(data)
      return data unless data.is_a?(Hash)

      data.to_h do |key, value|
        next [ key.to_s, "***MASKED***" ] if SENSITIVE_FIELDS.any? { |f| key.to_s.downcase.include?(f) }

        [ key.to_s, mask_sensitive(value) ]
      end
    end

    def log_debug(message, **context)
      Rails.logger.debug { AppLog.format_line(message, context) }
    end
  end
end
