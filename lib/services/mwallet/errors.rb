# frozen_string_literal: true

# MWallet Errors
# Error classes for mwallet API integration

module MWalletError
  # Base error class
  class Base < StandardError
    attr_reader :code, :details

    def initialize(message, code: nil, details: nil)
      super(message)
      @code = code
      @details = details
    end
  end

  # Network/connection errors
  class NetworkError < Base; end

  # Timeout errors
  class ProviderTimeout < Base; end

  # Signature verification errors
  class SignatureError < Base; end

  # Business logic errors
  class BusinessError < Base; end

  # Invoice already paid
  class InvoiceAlreadyPaidError < BusinessError; end

  # Invoice not cancellable
  class InvoiceNotCancellableError < BusinessError; end

  # Refund limit exceeded
  class RefundLimitExceededError < BusinessError; end

  # Invoice not found
  class InvoiceNotFoundError < BusinessError; end

  # Validation error
  class ValidationError < BusinessError; end

  # Classify error from HTTP response
  def self.classify_from_response(response)
    status = response.status
    body = response.body || {}

    error_code = body['error_code'] || body[:error_code] || status
    error_message = body['error_message'] || body[:error_message] || body['message'] || "HTTP #{status}"

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
