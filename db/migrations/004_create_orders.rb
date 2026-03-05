# frozen_string_literal: true

# Migration: Create orders table
# This is the main table for tracking orders throughout their lifecycle

Sequel.migration do
  up do
    create_table :orders do
      primary_key :id
      
      # Payment provider identifier
      String :provider, default: 'ODENGI_QRPAY'
      
      # Unique invoice ID for idempotency
      # Format: "ORDER-{id}" or UUID
      String :merchant_invoice_id, unique: true, null: false
      
      # Client information
      BigInt :telegram_user_id, null: false
      String :client_display_name, null: false  # Snapshot of client name
      
      # Order details
      String :comment, size: 200  # Optional comment from client
      
      # Order status (see OrderStatus module)
      # NEW -> INVOICE_CREATED -> PAID -> IN_PROGRESS -> READY
      #                    |              |
      #                    v              v
      #                  EXPIRED       CANCELLED
      String :status, null: false, default: 'NEW'
      
      # Amount in tyiyn (smallest currency unit)
      Integer :total_amount, null: false
      String :currency, default: 'KGS'
      
      # Timestamps
      DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      
      # === Barista assignment ===
      BigInt :assigned_to_barista_id
      DateTime :assigned_at
      
      # === QRPay invoice data ===
      String :invoice_id_provider  # Invoice ID from QRPay
      String :qr_payload, text: true    # QR code payload string
      String :qr_url, text: true        # URL to QR code image
      String :qr_image_base64, text: true  # Base64 encoded QR image
      String :invoice_status_raw       # Raw status from provider
      DateTime :expires_at             # Invoice expiration time
      
      # === Diagnostics (truncated/masked) ===
      String :raw_create_request, text: true
      String :raw_create_response, text: true
      
      # === Notifications ===
      String :last_notified_status     # Last status client was notified about
    end
    
    # Indexes for common queries
    add_index :orders, [:status, :created_at]
    add_index :orders, [:telegram_user_id, :created_at]
    add_index :orders, :invoice_id_provider
    add_index :orders, :merchant_invoice_id, unique: true
  end

  down do
    drop_table :orders
  end
end
