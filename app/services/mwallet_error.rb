# frozen_string_literal: true

# Errors of the O!Dengi MWallet integration
module MWalletError
  class Base < StandardError
    attr_reader :code, :details

    def initialize(message = nil, code: nil, details: nil)
      super(message)
      @code = code
      @details = details
    end
  end

  # Connection problems, 5xx
  class NetworkError < Base; end

  # Timeouts (after retries)
  class ProviderTimeout < Base; end

  # Invalid callback signature, rejected credentials
  class SignatureError < Base; end

  # The provider refused the request ({"error": ..., "desc": ...})
  class BusinessError < Base; end

  class InvoiceAlreadyPaidError < BusinessError; end
  class InvoiceNotCancellableError < BusinessError; end
  class RefundLimitExceededError < BusinessError; end
  class InvoiceNotFoundError < BusinessError; end

  # Invalid request / callback body
  class ValidationError < BusinessError; end

  # Error for a non-2xx HTTP response
  #
  # @param response [Faraday::Response]
  # @return [MWalletError::Base]
  def self.classify_from_response(response)
    status = response.status
    body = response.body.is_a?(Hash) ? response.body : {}

    error_code = body["error_code"] || body[:error_code] || status
    error_message = body["error_message"] || body[:error_message] || body["message"] || "HTTP #{status}"

    case status
    when 400
      ValidationError.new(error_message, code: error_code, details: body)
    when 401, 403
      SignatureError.new("Authentication failed: #{error_message}", code: error_code, details: body)
    when 404
      InvoiceNotFoundError.new(error_message, code: error_code, details: body)
    when 408, 504
      ProviderTimeout.new(error_message, code: error_code, details: body)
    when 500..599
      NetworkError.new("Provider error: #{error_message}", code: error_code, details: body)
    else
      BusinessError.new(error_message, code: error_code, details: body)
    end
  end
end
