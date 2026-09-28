# frozen_string_literal: true

# MWallet Signer
# Handles request signing using HMAC-MD5 algorithm for mwallet API

require 'openssl'
require 'json'

module MWallet
  class Signer
    # Initialize with password
    def initialize(password)
      @password = password
    end

    # Sign a JSON request
    # The signature is computed over the entire JSON string (without the hash field)
    # using HMAC-MD5 algorithm
    #
    # @param json_string [String] The JSON string to sign (without hash field)
    # @return [String] HMAC-MD5 hash as lowercase hex string
    def sign(json_string)
      return nil if @password.nil? || @password.empty?

      # Compute HMAC-MD5
      signature = OpenSSL::HMAC.digest(
        OpenSSL::Digest.new('md5'),
        @password,
        json_string
      )

      # Return as lowercase hex string
      signature.unpack1('H*')
    end

    # Build JSON and sign it
    # Creates JSON without spaces/line breaks
    # then computes HMAC-MD5 signature
    #
    # @param params [Hash] The parameters to sign (must maintain insertion order)
    # @return [Hash] same hash with hash field added (modifies input!)
    def build_signed_request(params)
      # Create JSON without hash field (compact, no spaces)
      json_string = JSON.generate(params)

      # Compute signature
      signature = sign(json_string)

      # Add hash directly to input hash to preserve order
      params['hash'] = signature
      params
    end

    # Verify callback signature
    #
    # @param params [Hash] The callback parameters (with hash)
    # @return [Boolean] True if signature is valid
    def verify_callback(params)
      return false if params['hash'].nil? || params['hash'].empty?

      # Extract the hash from params
      provided_hash = params['hash']

      # Build params without hash for verification
      params_without_hash = params.reject { |k, _| k == 'hash' }

      # Compute expected hash
      json_string = JSON.generate(params_without_hash)
      expected_hash = sign(json_string)

      # Use constant-time comparison
      secure_compare(provided_hash, expected_hash)
    end

    private

    # Constant-time string comparison
    # Prevents timing attacks when comparing signatures
    def secure_compare(a, b)
      return false if a.nil? || b.nil?
      return false if a.bytesize != b.bytesize

      l = a.unpack('C*')
      r = b.unpack('C*')
      result = 0

      l.zip(r).each do |x, y|
        result |= x ^ y
      end

      result == 0
    end
  end
end
