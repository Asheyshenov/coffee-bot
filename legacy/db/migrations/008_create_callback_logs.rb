# frozen_string_literal: true

# Migration: Create callback_logs table
# Logs all incoming callbacks from QRPay for audit and deduplication

Sequel.migration do
  up do
    create_table :callback_logs do
      primary_key :id
      
      # Provider identification
      String :provider, default: 'ODENGI_QRPAY'
      
      # Event identification (for deduplication)
      String :event_id                       # Event ID from provider (if available)
      String :dedupe_key                     # Hash of raw_body + invoice_id for deduplication
      
      # Invoice references
      String :invoice_id_provider, index: true
      String :merchant_invoice_id, index: true
      
      # Callback data
      DateTime :received_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      String :raw_body, text: true, null: false
      
      # Security verification
      TrueClass :verified_signature, default: false
      
      # Processing status
      TrueClass :processed, default: false
      String :process_error                   # Error message if processing failed
      
      # Timestamps
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
    end
    
    # Indexes for deduplication queries
    add_index :callback_logs, :event_id, unique: true
    add_index :callback_logs, :dedupe_key
    add_index :callback_logs, [:invoice_id_provider, :received_at]
  end

  down do
    drop_table :callback_logs
  end
end
