# frozen_string_literal: true

require "rails_helper"

RSpec.describe MWallet::Signer do
  subject(:signer) { described_class.new("test-secret") }

  it "signs the compact JSON with HMAC-MD5 (lowercase hex)" do
    json = '{"invoice_id":"1","status":3}'

    expect(signer.sign(json)).to eq(OpenSSL::HMAC.hexdigest("md5", "test-secret", json))
  end

  it "appends the hash last, keeping the key order" do
    params = signer.build_signed_request({ "cmd" => "statusPayment", "data" => { "invoice_id" => "1" } })

    expect(params.keys).to eq(%w[cmd data hash])
    expect(params["hash"]).to eq(signer.sign('{"cmd":"statusPayment","data":{"invoice_id":"1"}}'))
  end

  it "verifies its own signature and rejects other passwords, tampering and missing hashes" do
    params = signer.build_signed_request({ "invoice_id" => "1", "status" => 3, "amount" => 15_000 })

    expect(signer.verify_callback(params)).to be(true)
    expect(described_class.new("other-secret").verify_callback(params)).to be(false)
    expect(signer.verify_callback(params.merge("amount" => 1))).to be(false)
    expect(signer.verify_callback(params.except("hash"))).to be(false)
    expect(signer.verify_callback(params.merge("hash" => ""))).to be(false)
    expect(signer.verify_callback(params.merge("hash" => [ params["hash"] ]))).to be(false)
  end

  it "never verifies without a password" do
    params = described_class.new("x").build_signed_request({ "a" => 1 })

    expect(described_class.new(nil).verify_callback(params)).to be(false)
    expect(described_class.new("").sign("{}")).to be_nil
  end
end
