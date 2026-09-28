# frozen_string_literal: true

# QRPay Signer
# Handles request signing and signature verification
# Implements HMAC-SHA256 signature algorithm for O!Деньги QRPay API

require 'openssl'
require 'base64'
require 'json'

module QRPay
  class Signer
    # Initialize with secret key
    def initialize(secret_key)
      @secret_key = secret_key
    end

    # Sign a hash/params object
    # The signature is computed over specific fields in a specific order
    # as defined by the QRPay API documentation
    #
    # @param params [Hash] The parameters to sign
    # @param fields [Array] Optional - specific fields to include in signature
    # @return [String] Base64 encoded signature
    def sign(params, fields: nil)
      return nil if @secret_key.nil? || @secret_key.empty?

      # Build the string to sign
      string_to_sign = build_string_to_sign(params, fields)
      
      # Compute HMAC-SHA256
      signature = OpenSSL::HMAC.digest(
        OpenSSL::Digest.new('sha256'),
        @secret_key,
        string_to_sign
      )
      
      # Return Base64 encoded signature
      Base64.strict_encode64(signature)
    end

    # Verify a signature
    #
    # @param params [Hash] The parameters to verify
    # @param expected_signature [String] The signature to match
    # @param fields [Array] Optional - specific fields to include in signature
    # @return [Boolean] True if signature is valid
    def verify(params, expected_signature, fields: nil)
      return false if expected_signature.nil? || expected_signature.empty?

      computed = sign(params, fields: fields)
      
      # Use constant-time comparison to prevent timing attacks
      secure_compare(computed, expected_signature)
    end

    private

    # Build the string to sign from parameters
    # The format depends on the QRPay API specification
    # Common formats:
    # 1. Concatenated values: value1value2value3
    # 2. Key-value pairs: key1=value1&key2=value2
    # 3. JSON: {"key1":"value1","key2":"value2"}
    def build_string_to_sign(params, fields)
      if fields
        # Sign only specified fields in order
        values = fields.map { |f| params[f].to_s }
        values.join
      else
        # Sign all fields, sorted alphabetically
        sorted_params = params.to_a.sort_by(&:first)
        sorted_params.map { |k, v| "#{k}=#{v}" }.join('&')
      end
    end

    # Constant-time string comparison
    # Prevents timing attacks when comparing signatures
    def secure_compare(a, b)
      return false if a.nil? || b.nil?
      return false if a.bytesize != b.bytesize

      l = a.unpack("C*")
      r = b.unpack("C*")
      result = 0

      l.zip(r).each do |x, y|
        result |= x ^ y
      end

      result == 0
    end
  end

  # Signature builder for specific QRPay methods
  # Each method may have different fields to sign
  class SignatureBuilder
    # Fields to sign for createInvoice
    CREATE_INVOICE_FIELDS = %w[
      merchantId
      merchantInvoiceId
      amount
      currency
      description
      returnUrl
      resultUrl
    ].freeze

    # Fields to sign for getInvoiceStatus
    GET_STATUS_FIELDS = %w[
      merchantId
      merchantInvoiceId
    ].freeze

    # Fields to sign for cancelInvoice
    CANCEL_INVOICE_FIELDS = %w[
      merchantId
      merchantInvoiceId
    ].freeze

    # Fields to sign for refund
    REFUND_FIELDS = %w[
      merchantId
      merchantInvoiceId
      amount
    ].freeze

    # Fields to verify in callback
    CALLBACK_FIELDS = %w[
      invoiceId
      merchantInvoiceId
      status
      amount
    ].freeze

    attr_reader :signer

    def initialize(secret_key)
      @signer = Signer.new(secret_key)
    end

    # Sign createInvoice request
    def sign_create_invoice(params)
      signer.sign(params, fields: CREATE_INVOICE_FIELDS)
    end

    # Sign getInvoiceStatus request
    def sign_get_status(params)
      signer.sign(params, fields: GET_STATUS_FIELDS)
    end

    # Sign cancelInvoice request
    def sign_cancel_invoice(params)
      signer.sign(params, fields: CANCEL_INVOICE_FIELDS)
    end

    # Sign refund request
    def sign_refund(params)
      signer.sign(params, fields: REFUND_FIELDS)
    end

    # Verify callback signature
    def verify_callback(params, signature)
      signer.verify(params, signature, fields: CALLBACK_FIELDS)
    end
  end
end
