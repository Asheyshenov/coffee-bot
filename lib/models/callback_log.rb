# frozen_string_literal: true

# CallbackLog Model
# Logs all incoming callbacks from QRPay for audit and deduplication

require_relative '../../config/boot'
require 'digest'

class CallbackLog < Sequel::Model
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
  def self.duplicate?(event_id, invoice_id = nil, raw_body = nil)
    # First check by event_id (preferred)
    if event_id && !event_id.empty?
      return !by_event_id(event_id).nil?
    end

    # Fallback to dedupe_key
    return false if raw_body.nil?

    dedupe_key = generate_dedupe_key(raw_body, invoice_id)
    !where(dedupe_key: dedupe_key).first.nil?
  end

  # Generate deduplication key
  def self.generate_dedupe_key(raw_body, invoice_id = nil)
    hash = Digest::SHA256.hexdigest(raw_body.to_s)
    invoice_id ? "#{hash}-#{invoice_id}" : hash
  end

  # Create log entry
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
      process_error: error_message
    )
  end

  # Mark as verified
  def mark_verified!
    update(verified_signature: true)
  end

  # Check if duplicate
  def duplicate?
    return false if event_id.nil? || event_id.empty?
    self.class.where(event_id: event_id).where { id !~ id }.count > 0
  end
end
