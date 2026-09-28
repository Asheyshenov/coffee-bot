# frozen_string_literal: true

# Migration: Add emv_qr_url to orders table
# Stores the URL to the QR code image from MWallet

Sequel.migration do
  up do
    alter_table :orders do
      add_column :emv_qr_url, String, text: true
    end
  end

  down do
    alter_table :orders do
      drop_column :emv_qr_url
    end
  end
end
