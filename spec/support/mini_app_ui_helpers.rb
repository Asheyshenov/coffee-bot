# frozen_string_literal: true

# Telegram opens Mini App (web_app) buttons only over HTTPS, and the local .env decides
# PUBLIC_BASE_URL in tests too: specs of the Mini App buttons pin it.
module MiniAppUiHelpers
  def stub_public_base_url(url)
    allow(Rails.configuration.x).to receive(:public_base_url).and_return(url)
  end
end

RSpec.configure { |config| config.include MiniAppUiHelpers }
