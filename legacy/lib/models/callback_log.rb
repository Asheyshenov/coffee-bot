# frozen_string_literal: true

# CallbackLog Model
# Logs all incoming payment provider callbacks for audit and deduplication
#
# Deduplication is only an optimisation (skip re-processing an identical callback).
# Real idempotency comes from the atomic order status transition (Order#mark_paid!).

require_relative '../../config/boot'
require 'digest'

class CallbackLog < Sequel::Model
  DUPLICATE_ERROR = 'Duplicate callback'

  # Validations
  def validate
    super
    errors.add(:raw_body, 'cannot be empty') if raw_body.nil? || raw_body.empty?
  end

  # Scopes
  dataset_module do
    def unprocessed
      where(processed: false)
    end

    def verified
      where(verified_signature: true)
    end

    # Callbacks that were verified and processed without error
    def handled
      where(verified_signature: true, processed: true, process_error: nil)
    end

    def by_invoice_id(invoice_id)
      where(invoice_id_provider: invoice_id)
    end

    def by_event_id(event_id)
      where(event_id: event_id).first
    end

    def recent(limit = 100)
      order(Sequel.desc(:received_at)).limit(limit)
    end
  end

  # Class methods

  # Check for duplicate callback
  # A callback is a duplicate if one with the same provider event id, or with the
  # same raw body for the same invoice (dedupe_key), was already handled.
  # Failed or unverified attempts don't count, so a provider retry after an error
  # is processed again. Call this BEFORE logging the current callback.
  #
  # @param event_id [String, nil] Provider event id (nil if the provider has none)
  # @param invoice_id [String, nil] Provider invoice id
  # @param raw_body [String, nil] Raw request body
  # @return [Boolean]
  def self.duplicate?(event_id, invoice_id = nil, raw_body = nil)
    if event_id && !event_id.to_s.empty?
      return true unless handled.where(event_id: event_id.to_s).empty?
    end

    return false if raw_body.nil? || raw_body.empty?

    !handled.where(dedupe_key: generate_dedupe_key(raw_body, invoice_id)).empty?
  end

  # Generate deduplication key
  def self.generate_dedupe_key(raw_body, invoice_id = nil)
    hash = Digest::SHA256.hexdigest(raw_body.to_s)
    invoice_id ? "#{hash}-#{invoice_id}" : hash
  end

  # Create log entry
  # event_id must be a real per-event provider id (unique index) or nil -
  # never the invoice id, which repeats for every status update of the invoice.
  def self.log_callback(params)
    create(
      provider: params[:provider] || 'ODENGI_QRPAY',
      event_id: params[:event_id],
      invoice_id_provider: params[:invoice_id],
      merchant_invoice_id: params[:merchant_invoice_id],
      raw_body: params[:raw_body],
      verified_signature: params[:verified] || false,
      dedupe_key: generate_dedupe_key(params[:raw_body], params[:invoice_id])
    )
  end

  # Instance methods

  # Mark as processed
  def mark_processed!
    update(processed: true)
  end

  # Mark as failed with error
  def mark_failed!(error_message)
    update(
      processed: true,
      process_error: error_message.to_s[0, 255]
    )
  end

  # Mark as skipped duplicate
  def mark_duplicate!
    mark_failed!(DUPLICATE_ERROR)
  end

  # Mark as verified
  def mark_verified!
    update(verified_signature: true)
  end

  # Check if an equivalent callback was already handled before this one
  def duplicate?
    earlier = self.class.handled.exclude(id: id)
    return true if event_id && !event_id.empty? && !earlier.where(event_id: event_id).empty?

    !dedupe_key.nil? && !earlier.where(dedupe_key: dedupe_key).empty?
  end
end
