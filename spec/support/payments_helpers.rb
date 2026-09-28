# frozen_string_literal: true

# Helpers for payment specs: signed MWallet callbacks, stubbed provider responses,
# Telegram texts per chat.
module PaymentsHelpers
  # Callback params with the "hash" signature (made with the given account password)
  def signed_params(params, secret: TenancyHelpers::MWALLET_SECRET)
    MWallet::Signer.new(secret).build_signed_request(params.stringify_keys)
  end

  def signed_body(params, secret: TenancyHelpers::MWALLET_SECRET)
    signed_params(params, secret: secret).to_json
  end

  # statusPayment returns {"data": data} for every invoice
  def provider_returns(data)
    allow_any_instance_of(MWallet::Client).to receive(:get_status).and_return({ "data" => data })
  end

  # statusPayment returns one payment in data.payments[]
  def stub_provider_status(status:, amount: :none)
    payment = { "status" => status }
    payment["amount"] = amount unless amount == :none
    provider_returns("payments" => [ payment ])
  end

  # statusPayment confirms a payment (callbacks are applied only after this)
  def provider_confirms(amount: 15_000, status: "approved")
    stub_provider_status(status: status, amount: amount)
  end

  def texts_to(chat_id) = api.messages_to(chat_id).map { |m| m[:text] }

  # Move the order's creation time into the past (payment deadline passed)
  def make_overdue(order, minutes: 60)
    order.update_columns(created_at: minutes.minutes.ago)
    order.reload
  end

  def mwallet_service = MWallet::Service.new(current_tenant.payment_account)

  # Request specs: POST a callback to a payment account's result_url
  def post_callback(body, account: current_tenant.payment_account, content_type: "application/json")
    post "/pay/mwallet/#{account.id}", params: body, headers: { "CONTENT_TYPE" => content_type }
  end

  def json_body = JSON.parse(response.body)

  # Stale copy of a record, as another worker would hold it
  def stale_copy(order) = Order.find(order.id)

  def other_tenant(slug: "other-#{SecureRandom.hex(3)}", **options) = create_tenant(slug: slug, **options)

  # Run the jobs enqueued so far (and the ones they enqueue immediately), ignoring the
  # scheduled polling / expiry / late-payment chains unless asked for
  def perform_notifications
    perform_enqueued_jobs(only: Payments::NotifyResultJob)
  end
end

RSpec.configure do |config|
  config.include PaymentsHelpers
  config.include ActiveSupport::Testing::TimeHelpers
end
