# frozen_string_literal: true

# Migration: Create payments table
# Tracks payment information from QRPay

Sequel.migration do
  up do
    create_table :payments do
      primary_key :id
      
      # Reference to the order
      foreign_key :order_id, :orders, on_delete: :cascade, null: false
      
      # QRPay identifiers
      String :invoice_id_provider, index: true
      String :payment_id_provider  # Payment ID from QRPay after successful payment
      
      # Payment details
      Integer :paid_amount    # Amount actually paid in tyiyn
      Integer :fee            # Payment fee in tyiyn (if applicable)
      DateTime :paid_at       # When payment was confirmed
      
      # Normalized payment status
      # PENDING | PAID | FAILED | REFUNDED_PARTIAL | REFUNDED_FULL | VOIDED
      String :status, null: false, default: 'PENDING'
      
      # Raw response from provider (for debugging)
      String :raw_status_response, text: true
      
      # Timestamps
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at
    end
    
    add_index :payments, :invoice_id_provider
    add_index :payments, :order_id
  end

  down do
    drop_table :payments
  end
end
