# frozen_string_literal: true

# Migration: Create clients table
# Stores information about Telegram users who use the bot

Sequel.migration do
  up do
    create_table :clients do
      # Telegram user ID is the primary key
      # This is a BigInt to accommodate large Telegram IDs
      BigInt :telegram_user_id, primary_key: true
      
      # User profile information from Telegram
      String :username        # @username (may be null)
      String :first_name      # First name
      String :last_name       # Last name (may be null)
      String :language_code   # e.g., "en", "ru"
      
      # Statistics
      Integer :orders_count, default: 0
      
      # Timestamps
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :last_order_at
    end
  end

  down do
    drop_table :clients
  end
end
