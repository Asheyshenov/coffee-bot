# frozen_string_literal: true

require "digest"

# Every incoming payment callback, for audit and deduplication
class CallbackLog < ApplicationRecord
  DUPLICATE_ERROR = "Duplicate callback"

  acts_as_tenant :tenant

  belongs_to :payment_account, optional: true

  validates :raw_body, presence: true

  # Callbacks that were verified and processed without error
  scope :handled, -> { where(verified_signature: true, processed: true, process_error: nil) }

  # A callback is a duplicate if one with the same provider event id, or with the
  # same raw body for the same invoice (dedupe_key), was already handled.
  # Failed or unverified attempts don't count, so a provider retry after an error
  # is processed again. Call this BEFORE logging the current callback.
  def self.duplicate?(event_id, invoice_id = nil, raw_body = nil)
    return true if event_id.present? && handled.exists?(event_id: event_id.to_s)
    return false if raw_body.blank?

    handled.exists?(dedupe_key: dedupe_key_for(raw_body, invoice_id))
  end

  def self.dedupe_key_for(raw_body, invoice_id = nil)
    hash = Digest::SHA256.hexdigest(raw_body.to_s)
    invoice_id ? "#{hash}-#{invoice_id}" : hash
  end

  # event_id must be a real per-event provider id or nil - never the invoice id,
  # which repeats for every status update of the invoice
  def self.log_callback(payment_account:, raw_body:, invoice_id: nil, merchant_invoice_id: nil, event_id: nil)
    create!(
      payment_account: payment_account,
      provider: payment_account&.provider.to_s.upcase.presence || "MWALLET",
      event_id: event_id,
      invoice_id_provider: invoice_id,
      merchant_invoice_id: merchant_invoice_id,
      raw_body: raw_body,
      dedupe_key: dedupe_key_for(raw_body, invoice_id)
    )
  end

  def mark_verified! = update!(verified_signature: true)
  def mark_processed! = update!(processed: true)
  def mark_failed!(message) = update!(processed: true, process_error: message.to_s[0, 255])
  def mark_duplicate! = mark_failed!(DUPLICATE_ERROR)
end
