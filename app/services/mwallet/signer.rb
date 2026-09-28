# frozen_string_literal: true

require "openssl"
require "json"

module MWallet
  # HMAC-MD5 signatures of MWallet requests and callbacks.
  # The signature covers the compact JSON of the whole message without the "hash" field,
  # so key order matters: sign and verify hashes in the order they are sent / received.
  class Signer
    def initialize(password)
      @password = password
    end

    # @param json_string [String] compact JSON without the hash field
    # @return [String, nil] lowercase hex HMAC-MD5, nil without a password
    def sign(json_string)
      return nil if @password.blank?

      OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new("md5"), @password, json_string)
    end

    # Adds the "hash" field (last, keeping the order of the other keys).
    # Modifies and returns params.
    #
    # @param params [Hash] request with string keys
    # @return [Hash]
    def build_signed_request(params)
      params["hash"] = sign(JSON.generate(params))
      params
    end

    # @param params [Hash] callback with string keys, in the order received
    # @return [Boolean]
    def verify_callback(params)
      provided = params["hash"]
      return false unless provided.is_a?(String) && provided.present?

      expected = sign(JSON.generate(params.except("hash")))
      return false if expected.nil?

      ActiveSupport::SecurityUtils.secure_compare(provided.downcase, expected)
    end
  end
end
