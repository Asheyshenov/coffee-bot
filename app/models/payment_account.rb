# frozen_string_literal: true

# O!Dengi MWallet merchant credentials of a coffee shop.
# Not tenant-scoped: an incoming payment callback is routed to its tenant through the account.
class PaymentAccount < ApplicationRecord
  PROVIDERS = %w[mwallet].freeze
  TEST_BASE_URL = "https://mw-api-test.dengi.kg/api/json/json.php"

  belongs_to :tenant
  has_many :orders, dependent: :restrict_with_error

  encrypts :password

  validates :provider, inclusion: { in: PROVIDERS }
  validates :sid, :password, :base_url, presence: true
  validates :api_version, numericality: { only_integer: true }

  # MWallet sends payment results here (result_url of every invoice)
  def callback_url
    "#{Rails.configuration.x.public_base_url}/pay/mwallet/#{id}"
  end

  # HTTP client configured with this merchant's credentials
  def mwallet_client
    MWallet::Client.new(base_url: base_url, sid: sid, password: password, version: api_version, test_mode: test_mode)
  end
end
