# frozen_string_literal: true

# Nothing may leave the test process: Telegram and MWallet both go through Faraday
RSpec.configure do |config|
  config.before do
    allow_any_instance_of(Faraday::Connection).to receive(:run_request).and_raise("NETWORK DISABLED IN TESTS")
  end
end
