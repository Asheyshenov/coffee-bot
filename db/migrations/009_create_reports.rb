# frozen_string_literal: true

# Migration: Create reports table
# Tracks generated CSV reports from QRPay

Sequel.migration do
  up do
    create_table :reports do
      primary_key :id
      
      # Provider identification
      String :provider, default: 'ODENGI_QRPAY'
      
      # Report parameters
      Date :date_from, null: false
      Date :date_to, null: false
      String :filters_json, text: true  # JSON of additional filters
      
      # File information
      String :file_path, null: false    # Path to stored CSV file
      String :checksum                   # MD5/SHA checksum for integrity
      
      # Timestamps
      DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
    end
    
    add_index :reports, [:provider, :date_from, :date_to]
  end

  down do
    drop_table :reports
  end
end
