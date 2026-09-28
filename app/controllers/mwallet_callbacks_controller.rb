# frozen_string_literal: true

# POST /pay/mwallet/:payment_account_id - payment result callbacks of O!Dengi MWallet
# (result_url of every invoice issued from that payment account).
#
#   200 {"status":"ok"}    processed (or unknown invoice / duplicate / not confirmed: acknowledged)
#   200 {"status":"error"} unexpected error (logged; polling is the fallback)
#   400 empty or malformed body, 401 bad signature, 404 unknown account
#
# The account is looked up first (not tenant-scoped), everything else runs inside
# its coffee shop. Inactive (rotated) accounts are accepted: invoices issued before a
# credential change still point here. The signature is checked with that account's
# password, only that account's orders are looked up, and the callback is just a
# trigger - the payment is confirmed with statusPayment (see MWallet::Service).
# Notifications are delivered by a job, only for the winning result.
class MWalletCallbacksController < ActionController::API
  # The provider waits for the answer: confirm quickly or leave it to polling
  CLIENT_OPTIONS = { timeout: 10, retry_count: 0 }.freeze

  # The raw body is parsed (and its signature checked) by the action itself
  wrap_parameters false

  def create
    account = find_payment_account
    return render json: { error: "Not found" }, status: :not_found unless account

    ActsAsTenant.with_tenant(account.tenant) { handle_callback(account) }
  end

  private

  # Path parameter only: `params` would parse the body (and raise on malformed JSON)
  def find_payment_account
    id = request.path_parameters[:payment_account_id].to_s
    return nil unless id.match?(/\A\d+\z/)

    PaymentAccount.find_by(id: id)
  end

  def handle_callback(account)
    raw_body = request.raw_post.to_s
    AppLog.info("Received MWallet callback", payment_account_id: account.id, content_type: request.content_type,
                                             body_length: raw_body.bytesize)

    callback_params = parse_callback(raw_body)
    unless callback_params
      AppLog.error("Invalid MWallet callback body", payment_account_id: account.id, body_length: raw_body.bytesize)
      return render json: { error: "Invalid request body" }, status: :bad_request
    end

    result = MWallet::Service.new(account, **CLIENT_OPTIONS).process_callback(callback_params, raw_body)
    notify(result)
    render json: { status: "ok" }
  rescue MWalletError::SignatureError
    render json: { error: "Invalid signature" }, status: :unauthorized
  rescue MWalletError::ValidationError => e
    AppLog.error("Invalid MWallet callback", payment_account_id: account.id, error: e.message)
    render json: { error: "Invalid request body" }, status: :bad_request
  rescue StandardError => e
    # Acknowledged: polling / the expiry check are the fallback. Never expose details.
    AppLog.error("MWallet callback processing error", payment_account_id: account.id, error: "#{e.class}: #{e.message}",
                                                      backtrace: e.backtrace&.first(3)&.join(" | "))
    render json: { status: "error" }
  end

  # Only the caller that changed the order gets notification flags
  def notify(result)
    return unless result[:order_id] && (Payments::NotifyResultJob.notifiable?(result) || result[:invoice_cancelled])

    order = Order.find_by(id: result[:order_id])
    return unless order

    Payments::NotifyResultJob.notify_later(order, result) || Payments::NotifyResultJob.notify_invoice_cancelled_later(order, result)
  end

  # @return [Hash, nil] params with string keys in the order received; nil if the body
  #   is empty, malformed or not an object. A body that looks like JSON is parsed as
  #   JSON whatever the content type says, anything else as a form.
  def parse_callback(raw_body)
    body = raw_body.strip
    return nil if body.empty?

    data = if request.content_type.to_s.include?("json") || body.start_with?("{", "[")
      JSON.parse(body)
    else
      Rack::Utils.parse_nested_query(body)
    end
    data.is_a?(Hash) ? data.transform_keys(&:to_s) : nil
  rescue JSON::ParserError, Rack::Utils::ParameterTypeError, Rack::Utils::InvalidParameterError, Rack::BadRequest
    nil
  end
end
