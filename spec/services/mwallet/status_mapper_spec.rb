# frozen_string_literal: true

require "rails_helper"

RSpec.describe MWallet::StatusMapper do
  describe ".map_from_provider" do
    {
      3 => :paid, "3" => :paid, " 3 " => :paid, 3.0 => :paid, "approved" => :paid, "SUCCESS" => :paid,
      2 => :cancelled, "2" => :cancelled, "canceled" => :cancelled, "cancelled" => :cancelled, "rejected" => :cancelled,
      "expired" => :cancelled,
      1 => :pending, "4" => :pending, 8 => :pending, 9 => :pending, "processing" => :pending, "wait" => :pending,
      6 => :partial_refund,
      nil => :unknown, 5 => :unknown, "on_hold_by_bank" => :unknown, 3.5 => :unknown, {} => :unknown, true => :unknown
    }.each do |status, expected|
      it "maps #{status.inspect} to #{expected}" do
        expect(described_class.map_from_provider(status)).to eq(expected)
      end
    end
  end

  it "knows final, paid and pending codes" do
    expect(described_class.final_status?("3")).to be(true)
    expect(described_class.final_status?(1)).to be(false)
    expect(described_class.paid?(3)).to be(true)
    expect(described_class.pending?("8")).to be(true)
    expect(described_class.description(2)).to eq("Аннулирован")
  end
end
