# frozen_string_literal: true

# QRPay Error Classes
# Custom exceptions for different error scenarios

module QRPayError
  # Base error class
  class Base < StandardError
    attr_reader :code, :details

    def initialize(message, code: nil, details: nil)
      super(message)
      @code = code
      @details = details
    end
  end

  # Authentication error (invalid credentials or signature)
  class AuthError < Base; end

  # Validation error (invalid request parameters)
  class ValidationError < Base; end

  # Provider timeout error
  class ProviderTimeout < Base; end

  # Provider error (5xx or unexpected response)
  class ProviderError < Base; end

  # Business logic error (e.g., cannot cancel paid invoice)
  class BusinessError < Base; end

  # Unknown error
  class UnknownError < Base; end

  # Invoice not found
  class InvoiceNotFoundError < Base; end

  # Invoice already paid
  class InvoiceAlreadyPaidError < BusinessError; end

  # Invoice cannot be cancelled
  class InvoiceNotCancellableError < BusinessError; end

  # Refund limit exceeded
  class RefundLimitExceededError < BusinessError; end

  # Network error
  class NetworkError < Base; end

  # Signature verification failed
  class SignatureError < Base; end

  # Helper method to classify errors from response
  def self.classify_from_response(response)
    return ProviderTimeout.new('Request timeout') if response.nil?

    status = response.status
    body = response.body rescue {}

    case status
    when 401, 403
      AuthError.new('Authentication failed', code: status, details: body)
    when 400
      ValidationError.new('Validation error', code: status, details: body)
    when 404
      InvoiceNotFoundError.new('Invoice not found', code: status, details: body)
    when 408
      ProviderTimeout.new('Request timeout', code: status, details: body)
    when 500..599
      ProviderError.new('Provider error', code: status, details: body)
    else
      UnknownError.new('Unknown error', code: status, details: body)
    end
  end
end
